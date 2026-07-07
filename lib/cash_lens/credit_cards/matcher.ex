defmodule CashLens.CreditCards.Matcher do
  @moduledoc "Auto-links a statement to its exact-amount payment on import."
  import Ecto.Query
  alias CashLens.Accounts.Account
  alias CashLens.Categories
  alias CashLens.CreditCards
  alias CashLens.CreditCards.Statement
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  @window_days 15

  def auto_link(statement, line_total) do
    case credit_card_category_ids() do
      [] ->
        :no_match

      category_ids ->
        target = statement.total_a_pagar || line_total
        ref = statement.due_date

        candidates =
          from(t in Transaction,
            where: t.category_id in ^category_ids,
            where: t.account_id != ^statement.account_id,
            where: is_nil(t.parent_transaction_id),
            where: t.amount == ^target or t.amount == ^Decimal.negate(target)
          )
          |> Repo.all()
          |> Enum.filter(&within_window?(&1, ref))

        case candidates do
          [payment] ->
            {:ok, _} = CreditCards.link_payment(statement, payment.id)
            {:linked, payment}

          [] ->
            :no_match

          _ ->
            :ambiguous
        end
    end
  end

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
  @spec match_payment(Transaction.t() | map(), Ecto.UUID.t() | nil) ::
          {:linked, Statement.t()} | :no_match | :ambiguous | :not_credit_card_category
  def match_payment(payment, credit_card_account_id \\ nil) do
    category_ids = credit_card_category_ids()

    cond do
      category_ids == [] ->
        :not_credit_card_category

      payment.category_id not in category_ids ->
        :not_credit_card_category

      already_linked?(payment) ->
        :no_match

      true ->
        account_ids =
          if credit_card_account_id,
            do: [credit_card_account_id],
            else: all_credit_card_account_ids()

        account_ids
        |> open_statements()
        |> Enum.reject(&(&1.account_id == Map.get(payment, :account_id)))
        |> Enum.filter(&statement_matches_payment?(&1, payment))
        |> do_match_payment(payment)
    end
  end

  # A payment counts as a credit-card payment if its category is
  # "cartao-de-credito" OR any descendant (users file bill payments under
  # per-card children like `cartao-de-credito-amex` and
  # `cartao-de-credito-pagamento`, not the bare parent slug). Returns [] when
  # the parent category doesn't exist.
  defp credit_card_category_ids do
    case Categories.get_category_by_slug("cartao-de-credito") do
      nil -> []
      category -> Categories.get_category_ids_with_children(category.id)
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
  defp already_linked?(payment) do
    not is_nil(Map.get(payment, :parent_transaction_id)) or
      already_linked_statement_exists?(Map.get(payment, :id))
  end

  defp already_linked_statement_exists?(nil), do: false

  defp already_linked_statement_exists?(payment_id) do
    Repo.exists?(from(s in Statement, where: s.payment_transaction_id == ^payment_id))
  end

  defp do_match_payment([], _payment), do: :no_match

  defp do_match_payment([statement], payment) do
    {:ok, statement} = CreditCards.link_payment(statement, payment.id)
    {:linked, statement}
  end

  defp do_match_payment(_statements, _payment), do: :ambiguous

  defp statement_matches_payment?(statement, payment) do
    target = statement.total_a_pagar || line_total(statement)
    ref = statement.due_date

    (Decimal.equal?(target, payment.amount) or
       Decimal.equal?(target, Decimal.negate(payment.amount))) and
      within_window?(payment, ref)
  end

  defp line_total(statement) do
    statement.id
    |> CreditCards.statement_transactions()
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
  end

  defp open_statements(account_ids) do
    from(s in Statement,
      where: s.account_id in ^account_ids,
      where: is_nil(s.payment_transaction_id)
    )
    |> Repo.all()
  end

  defp all_credit_card_account_ids do
    from(a in Account, where: a.is_credit_card == true, select: a.id)
    |> Repo.all()
  end

  defp within_window?(_payment, nil), do: true
  defp within_window?(payment, ref), do: abs(Date.diff(payment.date, ref)) <= @window_days
end
