defmodule CashLens.CreditCards.Matcher do
  @moduledoc """
  Auto-links a statement to its exact-amount payment on import.

  Every function takes the `%CashLens.Users.User{}` it acts for first and only
  considers that user's statements, accounts, categories and transactions.
  """
  import Ecto.Query
  alias CashLens.Accounts.Account
  alias CashLens.Categories
  alias CashLens.CreditCards
  alias CashLens.CreditCards.Statement
  alias CashLens.Ownership
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Users.User

  @window_days 15

  def auto_link(%User{} = user, statement, line_total) do
    case credit_card_category_ids(user) do
      [] ->
        :no_match

      category_ids ->
        user
        |> exact_amount_payments(category_ids, statement, line_total)
        |> link_single_candidate(user, statement)
    end
  end

  defp exact_amount_payments(user, category_ids, statement, line_total) do
    target = statement.total_a_pagar || line_total
    ref = statement.due_date
    accounts = Ownership.scope(Account, user)

    from(t in Ownership.scope(Transaction, user),
      join: a in ^accounts,
      on: a.id == t.account_id,
      where: t.category_id in ^category_ids,
      # Money settling a bill leaves a bank account, never another card.
      # Excluding only the statement's own account let the CARD side of
      # some other card's payment -- a positive credit of the same
      # amount, sitting on that card -- be auto-linked here.
      where: not a.is_credit_card,
      where: is_nil(t.parent_transaction_id),
      where: t.amount == ^target or t.amount == ^Decimal.negate(target)
    )
    |> Repo.all()
    |> Enum.filter(&within_window?(&1, ref))
  end

  defp link_single_candidate([payment], user, statement) do
    case CreditCards.link_payment(user, statement, payment.id) do
      {:ok, _} -> {:linked, payment}
      # Not the user's own statement: nothing to link.
      {:error, :not_found} -> :no_match
    end
  end

  defp link_single_candidate([], _user, _statement), do: :no_match
  defp link_single_candidate(_candidates, _user, _statement), do: :ambiguous

  @doc """
  Mirror image of `auto_link/2`: given a payment (the debit leaving a
  non-card account), finds the matching OPEN statement (no payment linked
  yet) whose total matches the payment's amount within the date window,
  and links it — updating both the statement and its children.

  `credit_card_account_id` narrows the search to one card account when the
  caller knows it (e.g. a `TransferRule`'s destination); pass `nil` to
  search across every credit-card account.

  `payment` may be a persisted `%Transaction{}` or a bare map with
  `:id, :category_id, :amount, :date`.
  """
  @spec match_payment(struct(), Transaction.t() | map(), Ecto.UUID.t() | nil) ::
          {:linked, Statement.t()} | :no_match | :ambiguous | :not_credit_card_category
  def match_payment(%User{} = user, payment, credit_card_account_id \\ nil) do
    category_ids = credit_card_category_ids(user)

    cond do
      category_ids == [] ->
        :not_credit_card_category

      payment.category_id not in category_ids ->
        :not_credit_card_category

      already_linked?(user, payment) ->
        :no_match

      true ->
        account_ids =
          if credit_card_account_id,
            do: [credit_card_account_id],
            else: all_credit_card_account_ids(user)

        account_ids
        |> then(&open_statements(user, &1))
        |> Enum.reject(&(&1.account_id == Map.get(payment, :account_id)))
        |> Enum.filter(&statement_matches_payment?(user, &1, payment))
        |> then(&do_match_payment(user, &1, payment))
    end
  end

  # A payment counts as a credit-card payment if its category is
  # "cartao-de-credito" OR any descendant (users file bill payments under
  # per-card children like `cartao-de-credito-amex` and
  # `cartao-de-credito-pagamento`, not the bare parent slug). Returns [] when
  # the parent category doesn't exist.
  defp credit_card_category_ids(user) do
    case Categories.get_category_by_slug(user, "cartao-de-credito") do
      nil -> []
      category -> Categories.get_category_ids_with_children(user, category.id)
    end
  end

  # A payment is "already linked" if either:
  #   - it carries its own `parent_transaction_id` (defensive: mirrors the
  #     `is_nil(t.parent_transaction_id)` guard `auto_link/2` applies to
  #     candidate payments), or
  #   - some statement already points at it via `payment_transaction_id`
  #     (the real-world case: `link_payment/2` stamps the statement, not the
  #     payment, so re-running matching for the same payment must consult
  #     the statement side to avoid co-linking it to a second statement).
  defp already_linked?(user, payment) do
    not is_nil(Map.get(payment, :parent_transaction_id)) or
      already_linked_statement_exists?(user, Map.get(payment, :id))
  end

  defp already_linked_statement_exists?(_user, nil), do: false

  defp already_linked_statement_exists?(user, payment_id) do
    Repo.exists?(
      from(s in Ownership.scope(Statement, user), where: s.payment_transaction_id == ^payment_id)
    )
  end

  defp do_match_payment(_user, [], _payment), do: :no_match

  defp do_match_payment(user, [statement], payment) do
    case CreditCards.link_payment(user, statement, payment.id) do
      {:ok, statement} -> {:linked, statement}
      {:error, :not_found} -> :no_match
    end
  end

  defp do_match_payment(_user, _statements, _payment), do: :ambiguous

  defp statement_matches_payment?(user, statement, payment) do
    target = statement.total_a_pagar || line_total(user, statement)
    ref = statement.due_date

    (Decimal.equal?(target, payment.amount) or
       Decimal.equal?(target, Decimal.negate(payment.amount))) and
      within_window?(payment, ref)
  end

  defp line_total(user, statement) do
    user
    |> CreditCards.statement_transactions(statement.id)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
  end

  defp open_statements(user, account_ids) do
    from(s in Ownership.scope(Statement, user),
      where: s.account_id in ^account_ids,
      where: is_nil(s.payment_transaction_id)
    )
    |> Repo.all()
  end

  defp all_credit_card_account_ids(user) do
    from(a in Ownership.scope(Account, user), where: a.is_credit_card == true, select: a.id)
    |> Repo.all()
  end

  defp within_window?(_payment, nil), do: true
  defp within_window?(payment, ref), do: abs(Date.diff(payment.date, ref)) <= @window_days
end
