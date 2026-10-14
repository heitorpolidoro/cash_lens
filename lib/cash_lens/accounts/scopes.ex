defmodule CashLens.Accounts.Scopes do
  @moduledoc """
  Query scopes expressing "cash accounts only", i.e. accounts whose
  `is_credit_card` flag is `false`.

  ## Who uses this

  The global screens and reports, which must consider money that actually moved
  through a bank account and never the card charges that will be settled later
  by a single bill payment:

    * the dashboard summaries (`CashLens.Transactions.get_monthly_summary/2`
      when no specific account is selected, and
      `CashLens.Transactions.get_historical_summary/1`);
    * the transfers screens (transfer suggestions, unmatched transfers and
      manual link candidates in `CashLens.Transactions`);
    * the forecast category suggestions
      (`CashLens.Forecast.suggest_for_category/1`).

  ## Who must NOT use this

  `CashLens.Installments`, `CashLens.CreditCards` (including
  `CashLens.CreditCards.Matcher`) and the credit-card branches of
  `CashLens.Forecast` must never apply these scopes. (The per-user filter
  `CashLens.Ownership.scope/2` is a different thing: those modules apply it on
  every table they read or write.)

  Installment purchases are made *on* credit-card accounts: every
  installment-linked transaction in the production database sits on one. The
  forecast discloses future card bills and their installment breakdown by
  reaching into `CashLens.Installments`. Applying a cash-accounts scope to any
  query those code paths depend on would drop every installment row, emptying
  the forecast's installment disclosure silently — no error, no crash, just
  zeroed totals. The guard tests in `test/cash_lens/installments_scope_guard_test.exs`
  and `test/cash_lens/forecast_scope_guard_test.exs` exist to catch exactly that.

  `CashLens.Accounts.list_bank_accounts/0` and
  `CashLens.Accounts.list_credit_card_accounts/0` also stay as they are: they
  *define* the two sets rather than consume them.
  """

  import Ecto.Query

  @doc """
  Restricts `query` — whose root schema has an `:account` association, in
  practice `CashLens.Transactions.Transaction` — to rows on cash accounts.

  Joins the account itself under the named binding `:cash_scope_account`, so it
  can be applied to a query that has not named any account binding yet.

      Transaction |> Scopes.cash_accounts_only() |> Repo.all()
  """
  def cash_accounts_only(query) do
    query
    |> join(:inner, [t], a in assoc(t, :account), as: :cash_scope_account)
    |> cash_account_binding(:cash_scope_account)
  end

  @doc """
  Like `cash_accounts_only/1`, but the joined account is also restricted to the
  accounts `user` owns (`CashLens.Ownership.scope/2`), so a transaction never
  matches through another user's account.
  """
  def cash_accounts_only(query, %CashLens.Users.User{} = user) do
    accounts = CashLens.Ownership.scope(CashLens.Accounts.Account, user)

    query
    |> join(:inner, [t], a in ^accounts, on: a.id == t.account_id, as: :cash_scope_account)
    |> cash_account_binding(:cash_scope_account)
  end

  @doc """
  Applies the cash-accounts predicate to an account binding the caller has
  already named with `as:`.

  Used when a query joins more than one account — the two-sided transfer
  self-join — or when the account is already joined for other reasons.

      from(t in Transaction, join: a in assoc(t, :account), as: :acct)
      |> Scopes.cash_account_binding(:acct)
  """
  def cash_account_binding(query, binding) when is_atom(binding) do
    where(query, [{^binding, a}], a.is_credit_card == false)
  end
end
