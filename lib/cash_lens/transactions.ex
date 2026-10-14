defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.

  Every function that touches rows takes the `%CashLens.Users.User{}` it acts
  for as its first argument and filters every table it reads (joins and
  subqueries included) through `CashLens.Ownership.scope/2`. Reads of another
  user's rows come back empty (or raise `Ecto.NoResultsError` for `get_*!`),
  and writes on another user's record return `{:error, :not_found}` and leave
  it unchanged.
  """

  import Ecto.Query, warn: false
  alias CashLens.Accounts.Account
  alias CashLens.Accounts.Scopes
  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.CreditCards.Matcher, as: CreditCardMatcher
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Ownership
  alias CashLens.Repo
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.BulkIgnorePattern
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.RejectedReimbursementPair
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.TransferRule
  alias CashLens.Transactions.TransferRuleApplier
  alias CashLens.Users.User

  @default_page_size 50

  # Maximum number of days between the two sides of an automatically suggested
  # transfer pair.
  @transfer_pairing_window_days 3

  # Date window used when listing manual-link candidates in the transfers modal.
  @transfer_link_window_days 30

  # Maximum number of manual-link candidates shown at once.
  @transfer_link_candidate_limit 50

  # How far a confirmed manual duplicate will walk looking for a free occurrence
  # index. A charge repeated fifty times in one day with the same amount and
  # description is a data problem, not a purchase history, and the search gives
  # up rather than scanning forever.
  @max_occurrence_index 50

  @doc """
  Rows returned per page by `list_transactions/4`. Exposed so the transactions
  LiveView can tell a full page (there may be more) from a short one (the
  infinite scroll reached the end) without hardcoding the same number twice.
  """
  def default_page_size, do: @default_page_size

  # --- Ownership helpers -----------------------------------------------------

  # The user's row of `schema` with `id`, or nil (also for an id that is not a
  # valid UUID, which can only be somebody else's or nobody's).
  defp fetch_owned(schema, %User{} = user, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> schema |> Ownership.scope(user) |> Repo.get(id)
      :error -> nil
    end
  end

  # Re-fetches `record` as the user's own and updates/deletes the fetched row.
  # Anyone else's record is `{:error, :not_found}` and stays unchanged.
  defp update_owned(schema, user, %{id: id}, build_changeset) do
    case fetch_owned(schema, user, id) do
      nil -> {:error, :not_found}
      current -> current |> build_changeset.() |> Repo.update()
    end
  end

  defp delete_owned(schema, user, %{id: id}) do
    case fetch_owned(schema, user, id) do
      nil -> {:error, :not_found}
      current -> Repo.delete(current)
    end
  end

  # True when every id names a transaction the user owns.
  defp all_owned?(_user, []), do: true

  defp all_owned?(user, ids) do
    ids = Enum.uniq(ids)

    valid =
      Enum.flat_map(ids, fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)

    length(valid) == length(ids) and
      Repo.aggregate(
        from(t in Ownership.scope(Transaction, user), where: t.id in ^valid),
        :count
      ) == length(ids)
  end

  defp owned_query(:account, user), do: Ownership.scope(Account, user)
  defp owned_query(:category, user), do: Ownership.scope(Category, user)
  defp owned_query(:installment_group, user), do: Ownership.scope(InstallmentGroup, user)

  # `preload` entries restricted to the user's own rows.
  defp owned_preloads(user, assocs), do: Enum.map(assocs, &{&1, owned_query(&1, user)})

  defp preload_owned(structs, user, assocs),
    do: Repo.preload(structs, owned_preloads(user, assocs))

  # --- Transfer rules ----------------------------------------------------------

  @doc """
  Returns the list of the user's transfer rules, preloading source and destination accounts.
  """
  def list_transfer_rules(%User{} = user) do
    Repo.all(
      from r in Ownership.scope(TransferRule, user),
        order_by: [asc: r.inserted_at],
        preload:
          ^[
            source_account: owned_query(:account, user),
            destination_account: owned_query(:account, user)
          ]
    )
  end

  def get_transfer_rule!(%User{} = user, id) do
    TransferRule
    |> Ownership.scope(user)
    |> Repo.get!(id)
    |> Repo.preload(
      source_account: owned_query(:account, user),
      destination_account: owned_query(:account, user)
    )
  end

  def create_transfer_rule(%User{} = user, attrs \\ %{}) do
    %TransferRule{user_id: user.id}
    |> TransferRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_transfer_rule(%User{} = user, %TransferRule{} = rule, attrs) do
    update_owned(TransferRule, user, rule, &TransferRule.changeset(&1, attrs))
  end

  def delete_transfer_rule(%User{} = user, %TransferRule{} = rule) do
    delete_owned(TransferRule, user, rule)
  end

  def change_transfer_rule(%TransferRule{} = rule, attrs \\ %{}) do
    TransferRule.changeset(rule, attrs)
  end

  # --- Bulk ignore patterns ----------------------------------------------------

  @doc """
  Returns the list of the user's bulk ignore patterns.
  """
  def list_bulk_ignore_patterns(%User{} = user) do
    Repo.all(from b in Ownership.scope(BulkIgnorePattern, user), order_by: [asc: b.pattern])
  end

  def list_transactions_by_description(%User{} = user, description) do
    Repo.all(
      from t in Ownership.scope(Transaction, user),
        where: t.description == ^description,
        order_by: [desc: t.date]
    )
  end

  def create_bulk_ignore_pattern(%User{} = user, attrs \\ %{}) do
    %BulkIgnorePattern{user_id: user.id}
    |> BulkIgnorePattern.changeset(attrs)
    |> Repo.insert()
  end

  def update_bulk_ignore_pattern(%User{} = user, %BulkIgnorePattern{} = pattern, attrs) do
    update_owned(BulkIgnorePattern, user, pattern, &BulkIgnorePattern.changeset(&1, attrs))
  end

  def delete_bulk_ignore_pattern(%User{} = user, %BulkIgnorePattern{} = pattern) do
    delete_owned(BulkIgnorePattern, user, pattern)
  end

  def change_bulk_ignore_pattern(%BulkIgnorePattern{} = pattern, attrs \\ %{}) do
    BulkIgnorePattern.changeset(pattern, attrs)
  end

  def get_bulk_ignore_pattern!(%User{} = user, id) do
    BulkIgnorePattern |> Ownership.scope(user) |> Repo.get!(id)
  end

  # --- Listing, filtering and summaries -----------------------------------------

  @doc """
  Returns the filtered income and expenses totals, split by account kind.

  Returns
  `%{cash: %{income: Decimal, expenses: Decimal, count: integer},
     cards: %{income: Decimal, expenses: Decimal, count: integer}}`.
  A row belongs to `:cards` when its account's `is_credit_card` is `true`, and
  to `:cash` otherwise. Both keys are always present, zeroed when a side has no
  matching rows, so callers never pattern-match on a missing key.

  This function is deliberately **not** scoped to cash accounts: it backs the
  `/transactions` list, which shows every account. Mixing the two kinds into a
  single total is what the split prevents — a credit-card account's positive
  amounts are refunds and bill settlements, not income.
  """
  def get_filtered_summary(%User{} = user, filters \\ %{}) do
    accounts = owned_query(:account, user)

    base =
      Transaction
      |> Ownership.scope(user)
      |> apply_filters(user, filters)
      |> exclude_transfer_category(user)
      |> join(:left, [t], a in ^accounts, on: a.id == t.account_id, as: :summary_account)
      |> select([t, summary_account: a], %{amount: t.amount, is_credit_card: a.is_credit_card})

    from(row in subquery(base),
      group_by: row.is_credit_card,
      select: %{
        is_credit_card: row.is_credit_card,
        income: sum(fragment("CASE WHEN ? > 0 THEN ? ELSE 0 END", row.amount, row.amount)),
        expenses: sum(fragment("CASE WHEN ? < 0 THEN ABS(?) ELSE 0 END", row.amount, row.amount)),
        count: fragment("COUNT(*)")
      }
    )
    |> Repo.all()
    |> Enum.reduce(empty_filtered_summary(), fn row, acc ->
      group = if row.is_credit_card == true, do: :cards, else: :cash
      Map.update!(acc, group, &add_to_summary_group(&1, row))
    end)
  end

  @doc """
  The zeroed shape `get_filtered_summary/2` returns, with both groups present.
  """
  def empty_filtered_summary do
    %{cash: empty_summary_group(), cards: empty_summary_group()}
  end

  defp empty_summary_group do
    %{income: Decimal.new("0"), expenses: Decimal.new("0"), count: 0}
  end

  defp add_to_summary_group(group, row) do
    %{
      income: Decimal.add(group.income, row.income || Decimal.new("0")),
      expenses: Decimal.add(group.expenses, row.expenses || Decimal.new("0")),
      count: group.count + row.count
    }
  end

  # The filters shared by the list, the count and the summaries.
  defp apply_filters(query, user, filters) do
    query
    |> filter_by_account(filters["account_id"])
    |> filter_by_category(user, filters["category_id"])
    |> filter_by_description(filters["search"])
    |> filter_by_date(filters["date"])
    |> filter_by_date_range(filters["date_from"], filters["date_to"])
    |> filter_by_month_year(
      filters["month"],
      filters["year"],
      filters["category_id"],
      filters["unmatched_transfers"]
    )
    |> filter_by_amount(filters["amount"])
    |> filter_by_amount_range(filters["amount_min"], filters["amount_max"])
    |> filter_by_type(filters["type"])
    |> filter_by_reimbursement_status(filters["reimbursement_status"])
    |> filter_unmatched_transfers(user, filters["unmatched_transfers"])
  end

  def count_transactions(%User{} = user, filters \\ %{}) do
    Transaction
    |> Ownership.scope(user)
    |> join_associations(user)
    |> apply_filters(user, filters)
    |> Repo.aggregate(:count)
  end

  def list_transactions(
        %User{} = user,
        filters \\ %{},
        page \\ 1,
        page_size \\ @default_page_size
      ) do
    offset = (page - 1) * page_size
    sort_order = String.to_existing_atom(filters["sort_order"] || "desc")

    Transaction
    |> Ownership.scope(user)
    |> join_associations(user)
    |> apply_filters(user, filters)
    |> order_by_date(sort_order)
    |> limit(^page_size)
    |> offset(^offset)
    |> Repo.all()
    |> then(&CategorySuggester.annotate(user, &1))
  end

  @excluded_reimbursement_slugs [
    "transfer",
    "initial_value",
    "salário",
    "salario",
    "cartao-de-credito"
  ]

  def list_reimbursement_credit_candidates(%User{} = user, search \\ "") do
    excluded_ids = excluded_reimbursement_category_ids(user)
    accounts = owned_query(:account, user)
    categories = owned_query(:category, user)

    from(t in Ownership.scope(Transaction, user),
      join: acct in ^accounts,
      on: acct.id == t.account_id,
      left_join: c in ^categories,
      on: c.id == t.category_id,
      where: t.amount > 0,
      where: is_nil(t.reimbursement_link_key),
      where: is_nil(t.transfer_key),
      where: t.reimbursement_status != "paid" or is_nil(t.reimbursement_status),
      where: is_nil(c.slug) or c.slug not in ["transfer", "initial_value"],
      where: is_nil(t.category_id) or t.category_id not in ^excluded_ids,
      where: not ilike(t.description, "Transferência%"),
      order_by: [desc: t.date],
      preload: [category: c, account: acct]
    )
    |> then(fn q ->
      if search == "" do
        q
      else
        where(q, [t], ilike(t.description, ^"%#{search}%"))
      end
    end)
    |> Repo.all()
  end

  def list_all_transactions(%User{} = user, filters \\ %{}) do
    sort_order = String.to_existing_atom(filters["sort_order"] || "desc")

    Transaction
    |> Ownership.scope(user)
    |> join_associations(user)
    |> apply_filters(user, filters)
    |> filter_cash_accounts_only(user, filters["cash_accounts_only"])
    |> filter_out_reimbursement_linked(filters["exclude_reimbursement_linked"])
    |> order_by_date(sort_order)
    |> Repo.all()
  end

  # Opt-in: only the month closing screen drill-down passes this key, because
  # its totals no longer count reimbursement pairs and the expansion must add up
  # to the row it hangs under. The transactions screen omits the key and keeps
  # seeing both legs.
  defp filter_out_reimbursement_linked(query, flag) when flag in [true, "true"],
    do: where(query, [t], is_nil(t.reimbursement_link_key))

  defp filter_out_reimbursement_linked(query, _flag), do: query

  # Opt-in: only callers that report a cash-basis universe (the month closing
  # screen drill-down) pass this key, so every other caller keeps seeing the
  # credit-card accounts.
  defp filter_cash_accounts_only(query, user, flag) when flag in [true, "true"],
    do: Scopes.cash_accounts_only(query, user)

  defp filter_cash_accounts_only(query, _user, _flag), do: query

  defp filter_unmatched_transfers(query, user, "true") do
    categories = owned_query(:category, user)

    where(query, [t], t.transfer_key |> is_nil())
    |> join(:inner, [t], c in ^categories, on: c.id == t.category_id)
    |> where([..., c], c.slug == "transfer")
  end

  defp filter_unmatched_transfers(query, _user, _), do: query

  # Excludes transactions categorized as transfers or credit-card payments
  # from income/expense aggregates (the itemized purchases still count, just
  # not the lump-sum payment — see spec section 8).
  defp exclude_transfer_category(query, user) do
    excluded_ids =
      ["transfer", "cartao-de-credito"]
      |> Enum.map(&Categories.get_category_by_slug(user, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    if excluded_ids == [] do
      query
    else
      where(query, [t], is_nil(t.category_id) or t.category_id not in ^excluded_ids)
    end
  end

  defp filter_by_month_year(query, month, year, category_id, unmatched_transfers) do
    # Skip date filtering only when looking for pending/unmatched WITHOUT a specific month/year.
    # If month/year are specified, always apply them (e.g. month detail page uncategorized expand).
    has_month_year = month not in [nil, ""] or year not in [nil, ""]

    skip_date =
      not has_month_year and (category_id == "nil" or unmatched_transfers == "true")

    if skip_date do
      query
    else
      query
      |> filter_month(month)
      |> filter_year(year)
    end
  end

  defp filter_month(query, month) when month in [nil, ""], do: query

  defp filter_month(query, month) do
    m = if is_binary(month), do: String.to_integer(month), else: month
    where(query, [t], fragment("extract(month from ?)", t.date) == ^m)
  end

  defp filter_year(query, year) when year in [nil, ""], do: query

  defp filter_year(query, year) do
    y = if is_binary(year), do: String.to_integer(year), else: year
    where(query, [t], fragment("extract(year from ?)", t.date) == ^y)
  end

  defp order_by_date(query, :asc),
    do:
      order_by(query, [t],
        asc: t.date,
        asc_nulls_last: t.time,
        asc: t.inserted_at,
        asc: t.description,
        asc: t.id
      )

  defp order_by_date(query, _),
    do:
      order_by(query, [t],
        desc: t.date,
        desc_nulls_last: t.time,
        desc: t.inserted_at,
        asc: t.description,
        asc: t.id
      )

  defp join_associations(query, user) do
    preload(query, ^owned_preloads(user, [:category, :account, :installment_group]))
  end

  defp filter_by_date(query, nil), do: query
  defp filter_by_date(query, ""), do: query
  defp filter_by_date(query, date), do: where(query, date: ^date)

  defp filter_by_date_range(query, "", _), do: query
  defp filter_by_date_range(query, nil, _), do: query
  defp filter_by_date_range(query, _, ""), do: query
  defp filter_by_date_range(query, _, nil), do: query

  defp filter_by_date_range(query, from, to) do
    with {:ok, date_from} <- Date.from_iso8601(from),
         {:ok, date_to} <- Date.from_iso8601(to) do
      where(query, [t], t.date >= ^date_from and t.date <= ^date_to)
    else
      _ -> query
    end
  end

  defp filter_by_amount(query, nil), do: query
  defp filter_by_amount(query, ""), do: query

  defp filter_by_amount(query, amount) do
    # Remove whitespace, sign, and convert comma to dot
    amount_str =
      amount
      |> to_string()
      |> String.replace(~r/\s+/, "")
      |> String.replace(",", ".")
      |> String.replace("-", "")
      |> String.replace("+", "")

    if String.contains?(amount_str, ".") do
      clean_str = String.trim_trailing(amount_str, ".")

      case Decimal.cast(clean_str) do
        {:ok, dec} ->
          where(query, [t], fragment("abs(?)", t.amount) == ^dec)

        :error ->
          query
      end
    else
      case Integer.parse(amount_str) do
        {int_val, ""} ->
          min_val = Decimal.new(int_val)
          max_val = Decimal.new(int_val + 1)

          where(
            query,
            [t],
            fragment("abs(?)", t.amount) >= ^min_val and fragment("abs(?)", t.amount) < ^max_val
          )

        _ ->
          query
      end
    end
  end

  defp filter_by_type(query, type) when type in ["debit", "expense"],
    do: where(query, [t], t.amount < 0)

  defp filter_by_type(query, type) when type in ["credit", "income"],
    do: where(query, [t], t.amount > 0)

  defp filter_by_type(query, _), do: query

  defp filter_by_amount_range(query, min, max) do
    query
    |> then(fn q -> if min, do: where(q, [t], t.amount >= ^min), else: q end)
    |> then(fn q -> if max, do: where(q, [t], t.amount <= ^max), else: q end)
  end

  defp filter_by_reimbursement_status(query, nil), do: query
  defp filter_by_reimbursement_status(query, ""), do: query

  defp filter_by_reimbursement_status(query, status),
    do: where(query, reimbursement_status: ^status)

  defp filter_by_account(query, nil), do: query
  defp filter_by_account(query, ""), do: query
  defp filter_by_account(query, account_id), do: where(query, account_id: ^account_id)

  defp filter_by_category(query, _user, nil), do: query
  defp filter_by_category(query, _user, ""), do: query

  defp filter_by_category(query, _user, "nil") do
    where(query, [t], is_nil(t.category_id))
  end

  defp filter_by_category(query, user, category_id) do
    ids = Categories.get_category_ids_with_children(user, category_id)

    where(query, [t], t.category_id in ^ids)
  end

  defp filter_by_description(query, nil), do: query
  defp filter_by_description(query, ""), do: query

  defp filter_by_description(query, search) do
    where(query, [t], ilike(t.description, ^"%#{search}%"))
  end

  @doc """
  Lists the user's most recent transactions with a limit.
  """
  def list_recent_transactions(%User{} = user, limit \\ 5) do
    Repo.all(
      from t in Ownership.scope(Transaction, user),
        order_by: [desc: t.date, desc: t.inserted_at],
        limit: ^limit,
        preload: ^owned_preloads(user, [:category, :account, :installment_group])
    )
  end

  @doc """
  Calculates monthly totals for income (positive) and expenses (negative), ignoring transfers.
  Considers only the cash-accounts scope (`CashLens.Accounts.Scopes`) unless a specific
  account_id filter is passed.
  Includes credit-card bill payments (cartao-de-credito) on bank accounts as cash expenses.

  `opts` may carry `:excluded_category_ids`, the list `summary_excluded_category_ids/1`
  returned, so a caller making several summary reads resolves it once. Without it
  the ids are resolved here.
  """
  def get_monthly_summary(%User{} = user, date \\ nil, filters \\ %{}, opts \\ []) do
    filters = filters || %{}
    target_date = date || get_latest_transaction_date(user) || Date.utc_today()
    {first_of_month, last_of_month} = get_summary_period(target_date, filters)

    result =
      Transaction
      |> Ownership.scope(user)
      |> build_summary_base_query(user, excluded_ids(user, opts))
      |> apply_summary_date_filters(first_of_month, last_of_month, filters)
      |> apply_summary_account_filter(user, filters)
      |> aggregate_summary_totals()
      |> Repo.one()

    %{
      income: (result && result.income) || Decimal.new("0"),
      expenses: (result && result.expenses) || Decimal.new("0"),
      month: first_of_month
    }
  end

  @doc """
  Returns spending broken down by top-level category for a given month/year.

  Cash basis: only accounts with `is_credit_card == false` are considered, so a
  card purchase is never counted on its own — it reaches the month through the
  bill payment, which rolls up into a single "Cartão de Crédito" row. Transfers
  and initial values stay excluded, and so does every transaction carrying a
  `reimbursement_link_key` — both legs of a reimbursement pair cancel out, as
  `get_historical_summary/2` already assumes.

  Returns list of maps: %{name: str, category_id: binary, type: str, total: Decimal}
  sorted by total descending.
  """
  def get_month_category_breakdown(%User{} = user, year, month)
      when is_integer(year) and is_integer(month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)
    categories = owned_query(:category, user)
    excluded_ids = excluded_cash_summary_category_ids(user)

    categorized =
      from(t in Ownership.scope(Transaction, user),
        join: c in ^categories,
        on: c.id == t.category_id,
        left_join: p in ^categories,
        on: p.id == c.parent_id,
        left_join: g in ^categories,
        on: g.id == p.parent_id,
        where: t.date >= ^first and t.date <= ^last,
        where: t.amount < 0,
        # Transfers and opening balances are not spending. Credit-card bill
        # payments ARE, on this cash-basis screen: they are the cash leaving the
        # current account for the purchases the card already carried.
        where: c.id not in ^excluded_ids,
        # A reimbursed expense and the credit that repays it cancel out, so
        # neither leg is spending. Only a link key marks an actual pair: an
        # expense merely flagged as awaiting a reimbursement still counts.
        where: is_nil(t.reimbursement_link_key),
        group_by: [
          fragment("COALESCE(?, ?, ?)", g.name, p.name, c.name),
          fragment("COALESCE(?, ?, ?)", g.id, p.id, c.id),
          fragment("COALESCE(?, ?, ?)", g.type, p.type, c.type)
        ],
        select: %{
          name: fragment("COALESCE(?, ?, ?)", g.name, p.name, c.name),
          category_id: type(fragment("COALESCE(?, ?, ?)", g.id, p.id, c.id), :binary_id),
          type: fragment("COALESCE(?, ?, ?)", g.type, p.type, c.type),
          total: sum(t.amount)
        },
        having: sum(t.amount) < 0,
        order_by: [asc: sum(t.amount)]
      )
      |> Scopes.cash_accounts_only(user)
      |> exclude_transactions_with_cash_children(user)
      |> Repo.all()
      |> Enum.map(fn row -> %{row | total: Decimal.abs(row.total)} end)

    uncategorized_total =
      from(t in Ownership.scope(Transaction, user),
        where: is_nil(t.category_id),
        where: t.amount < 0,
        where: t.date >= ^first and t.date <= ^last,
        where: is_nil(t.reimbursement_link_key),
        select: sum(fragment("ABS(?)", t.amount))
      )
      |> Scopes.cash_accounts_only(user)
      |> Repo.one()

    if is_nil(uncategorized_total) or Decimal.eq?(uncategorized_total, Decimal.new("0")) do
      categorized
    else
      [
        %{name: "Uncategorized", category_id: nil, type: nil, total: uncategorized_total}
        | categorized
      ]
    end
  end

  @doc """
  Returns income broken down by top-level category for a given month/year.

  Mirrors `get_month_category_breakdown/3` but for net-positive (income)
  categories, and on the same cash basis: only accounts with
  `is_credit_card == false` count. The whole `cartao-de-credito` subtree stays
  excluded here — a credit in it is the mirror of a bill payment, never income —
  and so does every transaction carrying a `reimbursement_link_key`, whose
  credit leg only gives back what the paired expense took out.

  Returns list of maps: %{name, category_id, type, total} sorted by total descending.
  """
  def get_month_income_breakdown(%User{} = user, year, month)
      when is_integer(year) and is_integer(month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)
    categories = owned_query(:category, user)
    excluded_ids = excluded_report_category_ids(user)

    categorized =
      from(t in Ownership.scope(Transaction, user),
        join: c in ^categories,
        on: c.id == t.category_id,
        left_join: p in ^categories,
        on: p.id == c.parent_id,
        left_join: g in ^categories,
        on: g.id == p.parent_id,
        where: t.date >= ^first and t.date <= ^last,
        where: t.amount > 0,
        where: c.id not in ^excluded_ids,
        # The credit leg of a reimbursement is not income: it gives back money
        # an expense of the same pair already took out. Only a link key marks an
        # actual pair (see `get_month_category_breakdown/3`).
        where: is_nil(t.reimbursement_link_key),
        group_by: [
          fragment("COALESCE(?, ?, ?)", g.name, p.name, c.name),
          fragment("COALESCE(?, ?, ?)", g.id, p.id, c.id),
          fragment("COALESCE(?, ?, ?)", g.type, p.type, c.type)
        ],
        select: %{
          name: fragment("COALESCE(?, ?, ?)", g.name, p.name, c.name),
          category_id: type(fragment("COALESCE(?, ?, ?)", g.id, p.id, c.id), :binary_id),
          type: fragment("COALESCE(?, ?, ?)", g.type, p.type, c.type),
          total: sum(t.amount)
        },
        having: sum(t.amount) > 0,
        order_by: [desc: sum(t.amount)]
      )
      |> Scopes.cash_accounts_only(user)
      |> Repo.all()

    uncategorized_total =
      from(t in Ownership.scope(Transaction, user),
        where: is_nil(t.category_id),
        where: t.amount > 0,
        where: t.date >= ^first and t.date <= ^last,
        where: is_nil(t.reimbursement_link_key),
        select: sum(t.amount)
      )
      |> Scopes.cash_accounts_only(user)
      |> Repo.one()

    if is_nil(uncategorized_total) or Decimal.eq?(uncategorized_total, Decimal.new("0")) do
      categorized
    else
      [
        %{name: "Uncategorized", category_id: nil, type: nil, total: uncategorized_total}
        | categorized
      ]
    end
  end

  defp get_summary_period(_target_date, %{"month" => m, "year" => y})
       when is_binary(m) and m != "" and is_binary(y) and y != "" do
    first = Date.new!(String.to_integer(y), String.to_integer(m), 1)
    {first, Date.end_of_month(first)}
  end

  defp get_summary_period(target_date, _filters) do
    first = Date.new!(target_date.year, target_date.month, 1)
    {first, Date.end_of_month(first)}
  end

  defp build_summary_base_query(query, user, excluded_ids) do
    categories = owned_query(:category, user)

    query
    |> join(:left, [t], c in ^categories, on: c.id == t.category_id)
    |> where([t, c], is_nil(c.id) or c.id not in ^excluded_ids)
    |> where([t], is_nil(t.reimbursement_link_key))
  end

  defp apply_summary_date_filters(query, _first, _last, %{"category_id" => "nil"}), do: query

  defp apply_summary_date_filters(query, _first, _last, %{"unmatched_transfers" => "true"}),
    do: query

  defp apply_summary_date_filters(query, first, last, _filters) do
    where(query, [t], t.date >= ^first and t.date <= ^last)
  end

  defp apply_summary_account_filter(query, user, filters) do
    case Map.get(filters, "account_id") || Map.get(filters, :account_id) do
      account_id when account_id in [nil, ""] ->
        Scopes.cash_accounts_only(query, user)

      account_id ->
        where(query, [t], t.account_id == ^account_id)
    end
  end

  defp aggregate_summary_totals(query) do
    select(query, [t], %{
      income: sum(fragment("CASE WHEN ? > 0 THEN ? ELSE 0 END", t.amount, t.amount)),
      expenses: sum(fragment("CASE WHEN ? < 0 THEN ABS(?) ELSE 0 END", t.amount, t.amount))
    })
  end

  @doc """
  Returns pure income and expenses history grouped by month, excluding transfers.
  Considers only the cash-accounts scope (`CashLens.Accounts.Scopes`).

  Options: `:limit`, and `:excluded_category_ids` (see `get_monthly_summary/4`).
  """
  def get_historical_summary(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    excluded_ids = excluded_ids(user, opts)
    categories = owned_query(:category, user)

    cash_transactions = Scopes.cash_accounts_only(Ownership.scope(Transaction, user), user)

    query =
      from t in cash_transactions,
        left_join: c in ^categories,
        on: c.id == t.category_id,
        where: is_nil(c.id) or c.id not in ^excluded_ids,
        where: is_nil(t.reimbursement_link_key),
        group_by: [
          fragment("EXTRACT(YEAR FROM ?)::integer", t.date),
          fragment("EXTRACT(MONTH FROM ?)::integer", t.date)
        ],
        order_by: [
          desc: fragment("EXTRACT(YEAR FROM ?)::integer", t.date),
          desc: fragment("EXTRACT(MONTH FROM ?)::integer", t.date)
        ],
        select: %{
          year: fragment("EXTRACT(YEAR FROM ?)::integer", t.date),
          month: fragment("EXTRACT(MONTH FROM ?)::integer", t.date),
          income: sum(fragment("CASE WHEN ? > 0 THEN ? ELSE 0 END", t.amount, t.amount)),
          expenses: sum(fragment("CASE WHEN ? < 0 THEN ABS(?) ELSE 0 END", t.amount, t.amount))
        }

    query = if limit, do: limit(query, ^limit), else: query

    Repo.all(query)
    |> Enum.map(fn %{income: i, expenses: e} = row ->
      income = i || Decimal.new("0")
      expenses = e || Decimal.new("0")

      Map.merge(row, %{
        income: income,
        expenses: expenses,
        balance: Decimal.sub(income, expenses)
      })
    end)
    |> then(fn res ->
      if limit, do: Enum.sort_by(res, &{&1.year, &1.month}), else: res
    end)
  end

  @doc """
  Returns expense totals grouped by month and category, excluding transfers.
  """
  def get_historical_category_summary(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    res =
      historical_category_totals(user)
      |> Enum.group_by(&group_by_month_year/1)
      |> Enum.map(&format_month_summary/1)
      |> Enum.sort_by(fn %{year: y, month: m} -> {y, m} end, :desc)

    res = if limit, do: Enum.take(res, limit), else: res

    Enum.sort_by(res, fn %{year: y, month: m} -> {y, m} end)
  end

  defp historical_category_totals(user) do
    categories = owned_query(:category, user)
    excluded_ids = excluded_report_category_ids(user)

    from(t in Ownership.scope(Transaction, user),
      join: c in ^categories,
      on: c.id == t.category_id,
      left_join: p in ^categories,
      on: p.id == c.parent_id,
      where: t.amount < 0,
      # Category breakdown graphs: transfers and credit-card payments are not spending, so they are excluded.
      where: c.id not in ^excluded_ids,
      where: is_nil(t.reimbursement_link_key),
      where: t.reimbursement_status != "pending" or is_nil(t.reimbursement_status),
      select: %{
        year: fragment("EXTRACT(YEAR FROM ?)", t.date),
        month: fragment("EXTRACT(MONTH FROM ?)", t.date),
        category_name: c.name,
        parent_name: p.name,
        type: c.type,
        total: t.amount
      }
    )
    |> exclude_transactions_with_children(user)
    |> Repo.all()
  end

  # Category ids to exclude from cash flow summaries (monthly and historical):
  # transfers and initial opening balance. Credit-card bill payments (cartao-de-credito)
  # are real cash outflows on bank accounts, so they are INCLUDED in cash flow.
  @doc """
  Resolves the category ids the cash-flow summaries leave out (transfers and
  opening balances, with their subtrees).

  Costs four queries. A caller making several summary reads in one request
  calls this once and passes the result as `:excluded_category_ids`. It is not
  cached anywhere: the answer is only as fresh as the call.
  """
  def summary_excluded_category_ids(%User{} = user), do: excluded_cash_summary_category_ids(user)

  defp excluded_ids(user, opts),
    do:
      Keyword.get_lazy(opts, :excluded_category_ids, fn ->
        excluded_cash_summary_category_ids(user)
      end)

  defp excluded_cash_summary_category_ids(user) do
    category_ids_with_children(user, ["initial_value", "transfer"])
  end

  # Category ids to exclude from every income/expense report: transfers, the
  # opening-balance placeholder, and the WHOLE "cartao-de-credito" subtree —
  # not just the exact parent slug. Bill payments are bookkeeping mirrors
  # between the user's own accounts/statements (the outgoing debit AND the
  # matching credit inside the card account), never real income or spending,
  # and they're just as often filed under a per-card child category (e.g.
  # "cartao-de-credito-pagamento", "cartao-de-credito-ourocard") as under the
  # bare parent slug.
  defp excluded_report_category_ids(user) do
    category_ids_with_children(user, ["initial_value", "transfer", "cartao-de-credito"])
  end

  defp category_ids_with_children(user, slugs) do
    slugs
    |> Enum.map(&Categories.get_category_by_slug(user, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Categories.get_category_ids_with_children(user, &1.id))
    |> Enum.uniq()
  end

  # Transactions that are themselves a parent (another transaction points its
  # parent_transaction_id at them) are excluded from category-spend
  # breakdowns: their amount is the lump sum of their children, who already
  # carry the real categories. See spec section 7.
  defp exclude_transactions_with_children(query, user) do
    linked_parent_ids =
      from(c in Ownership.scope(Transaction, user),
        where: not is_nil(c.parent_transaction_id),
        distinct: true,
        select: c.parent_transaction_id
      )

    where(query, [t], t.id not in subquery(linked_parent_ids))
  end

  # Cash-basis variant of `exclude_transactions_with_children/2`, used only by
  # `get_month_category_breakdown/3`. On that screen the children sitting on
  # credit-card accounts are invisible, so hiding their parent would drop the
  # amount from the month altogether — the card bill payment is exactly such a
  # parent. A parent is therefore hidden only when at least one of its children
  # is itself on a cash account and thus already reported here.
  defp exclude_transactions_with_cash_children(query, user) do
    linked_parent_ids =
      from(c in Ownership.scope(Transaction, user),
        where: not is_nil(c.parent_transaction_id),
        distinct: true,
        select: c.parent_transaction_id
      )
      |> Scopes.cash_accounts_only(user)

    where(query, [t], t.id not in subquery(linked_parent_ids))
  end

  defp group_by_month_year(item) do
    year = if is_struct(item.year, Decimal), do: Decimal.to_integer(item.year), else: item.year

    month =
      if is_struct(item.month, Decimal), do: Decimal.to_integer(item.month), else: item.month

    {year, month}
  end

  defp format_month_summary({{year, month}, items}) do
    categories =
      items
      |> Enum.group_by(fn i -> {i.parent_name || i.category_name, i.type} end)
      |> Enum.map(&format_category_total/1)

    %{year: year, month: month, categories: categories}
  end

  defp format_category_total({{name, type}, txs}) do
    total =
      txs
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.total))
      |> Decimal.abs()

    %{name: name, type: type, total: total}
  end

  @doc """
  Returns the most recent date across every account of the user, or `nil` if
  the user has no transactions at all.
  """
  @spec get_latest_transaction_date(struct()) :: Date.t() | nil
  def get_latest_transaction_date(%User{} = user) do
    Repo.one(from t in Ownership.scope(Transaction, user), select: max(t.date))
  end

  @doc """
  Returns the most recent transaction date for `account_id`, or `nil` if the
  account has no transactions at all (or is not the user's).

  Only permanently-persisted rows (`source` of `"file"` or `"manual"`) count.
  """
  @spec latest_transaction_date(struct(), Ecto.UUID.t()) :: Date.t() | nil
  def latest_transaction_date(%User{} = user, account_id) do
    Repo.one(
      from t in Ownership.scope(Transaction, user),
        where: t.account_id == ^account_id and t.source in ["file", "manual"],
        select: max(t.date)
    )
  end

  @doc """
  Returns the most recent transaction date for `account_id` within `range`
  (inclusive), or `nil` if the account has no transaction in it.

  Only permanently-persisted rows (`source` of `"file"` or `"manual"`) count.
  """
  @spec latest_transaction_date_between(struct(), Ecto.UUID.t(), Date.t(), Date.t()) ::
          Date.t() | nil
  def latest_transaction_date_between(%User{} = user, account_id, from_date, to_date) do
    Repo.one(
      from t in Ownership.scope(Transaction, user),
        where:
          t.account_id == ^account_id and t.source in ["file", "manual"] and
            t.date >= ^from_date and t.date <= ^to_date,
        select: max(t.date)
    )
  end

  @doc """
  Returns a map of `%{account_id => latest_date}` for all the user's accounts
  having permanently-persisted transactions (`source` of `"file"` or `"manual"`).
  """
  @spec latest_transaction_dates(struct()) :: %{Ecto.UUID.t() => Date.t()}
  def latest_transaction_dates(%User{} = user) do
    from(t in Ownership.scope(Transaction, user),
      where: t.source in ["file", "manual"],
      group_by: t.account_id,
      select: {t.account_id, max(t.date)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # --- Single transaction ---------------------------------------------------------

  @doc """
  Gets a single transaction of the user, or `nil` when there is none (including
  when it belongs to somebody else).
  """
  def get_transaction(%User{} = user, id) do
    case fetch_owned(Transaction, user, id) do
      nil -> nil
      transaction -> preload_owned(transaction, user, [:category, :account, :installment_group])
    end
  end

  @doc """
  Gets a single transaction of the user; raises `Ecto.NoResultsError` for
  anyone else's.
  """
  def get_transaction!(%User{} = user, id) do
    case get_transaction(user, id) do
      nil -> raise Ecto.NoResultsError, queryable: Transaction
      transaction -> transaction
    end
  end

  @doc """
  Creates a transaction (manual single-create path) owned by `user`; a
  `"user_id"` in `attrs` is ignored.

  This path deliberately uses the default `occurrence_index` of 0, so a second
  identical submit (same dedupe base key) regenerates the same fingerprint and
  collides on the unique index — it is reported as `{:ok, :duplicate}` rather
  than inserted. That blocks accidental double-submits (e.g. a double-clicked
  form).

  This is intentionally different from the IMPORT path
  (`CashLens.Parsers.Ingestor`), which assigns per-batch occurrence indices so
  N legitimately-identical lines within one statement are all preserved. A
  manual create has no batch context to distinguish a genuine repeat from an
  accidental resubmit, so it errs toward not creating a duplicate.

  `allow_duplicate: true` is the caller saying it HAS that context -- a person
  who was shown the existing row and confirmed this is a second, real charge.
  The row is then written at the next free occurrence index, exactly as the
  importer would have done, so a genuine double charge stops being something
  that can only be recorded by falsifying its date.

  An `account_id` or `category_id` that is not the user's is a changeset error
  on that field.
  """
  def create_transaction(%User{} = user, attrs, opts \\ []) do
    attrs = maybe_allow_duplicate(user, attrs, Keyword.get(opts, :allow_duplicate, false))

    %Transaction{user_id: user.id}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} ->
        mirrors = TransferRuleApplier.maybe_apply_rule(user, transaction)

        twin_account_id =
          case TransferMatcher.match_transfer(user, transaction) do
            {:ok, id} -> id
            _ -> nil
          end

        maybe_match_credit_card_payment(user, transaction)

        # Rebuild balances for the original account
        rebuild_balances(user, transaction.account_id)

        # Rebuild balances for any mirror account
        Enum.each(mirrors, fn mirror ->
          rebuild_balances(user, mirror.account_id)
        end)

        # Rebuild balances for twin account if matched
        if twin_account_id do
          rebuild_balances(user, twin_account_id)
        end

        {:ok, transaction}

      {:error, changeset} ->
        if changeset.errors[:fingerprint] do
          {:ok, :duplicate}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  The user's transaction identical to `attrs`, if any -- same account,
  date, time, amount and normalized description.

  The question the manual-create form asks before writing a second one, and the
  reason it can ask at all: `dedup_key` is stored and indexed, so the existing
  charge is one lookup away.
  """
  def duplicate_of(%User{} = user, attrs) do
    case identity_of(user, attrs) do
      nil ->
        nil

      %{dedup_key: key} ->
        from(t in Ownership.scope(Transaction, user),
          where: t.dedup_key == ^key,
          order_by: [asc: t.inserted_at],
          limit: 1
        )
        |> Repo.one()
    end
  end

  # Form params arrive with string keys and uncast values -- a date as
  # "2026-09-08", an amount as a string -- while `Transaction.dedup_key/1`
  # requires atom keys and real structs. Running them through the changeset
  # normalizes both, and uses the very same casting the insert will, so the key
  # computed here cannot disagree with the one stored.
  defp identity_of(user, attrs) do
    changeset = Transaction.changeset(%Transaction{user_id: user.id}, attrs)

    case Ecto.Changeset.get_field(changeset, :dedup_key) do
      nil ->
        nil

      key ->
        %{
          dedup_key: key,
          attrs: %{
            date: Ecto.Changeset.get_field(changeset, :date),
            time: Ecto.Changeset.get_field(changeset, :time),
            description: Ecto.Changeset.get_field(changeset, :description),
            amount: Ecto.Changeset.get_field(changeset, :amount),
            account_id: Ecto.Changeset.get_field(changeset, :account_id)
          }
        }
    end
  end

  # The importer knows each line's ordinal within its batch; a confirmed manual
  # duplicate has to find the first ordinal nobody has taken. Walking upward
  # from zero is exact where counting rows is not: a deleted middle row leaves a
  # free index that a count would skip straight past, onto one already in use.
  defp maybe_allow_duplicate(_user, attrs, false), do: attrs

  defp maybe_allow_duplicate(user, attrs, true) do
    case identity_of(user, attrs) do
      nil ->
        attrs

      %{attrs: identity} ->
        put_attr(attrs, :occurrence_index, next_occurrence_index(user, identity))
    end
  end

  defp next_occurrence_index(user, attrs, index \\ 0)

  defp next_occurrence_index(_user, _attrs, index) when index >= @max_occurrence_index, do: index

  defp next_occurrence_index(user, attrs, index) do
    fingerprint = Transaction.fingerprint(attrs, index)

    if Repo.exists?(
         from(t in Ownership.scope(Transaction, user), where: t.fingerprint == ^fingerprint)
       ) do
      next_occurrence_index(user, attrs, index + 1)
    else
      index
    end
  end

  # The form hands params with string keys; everything else uses atoms. Ecto
  # rejects a map that mixes the two outright, so the key style is read from
  # what the map already holds -- not from whether this particular key is
  # present, which it never is, since nothing upstream sets the index.
  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end

  @doc """
  Updates one of the user's transactions; `{:error, :not_found}` (and no
  change) for anyone else's.
  """
  def update_transaction(%User{} = user, %Transaction{} = transaction, attrs) do
    case fetch_owned(Transaction, user, transaction.id) do
      nil ->
        {:error, :not_found}

      current ->
        do_update_transaction(user, current, attrs)
    end
  end

  defp do_update_transaction(user, current, attrs) do
    old_account_id = current.account_id

    current
    |> Transaction.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_transaction} ->
        maybe_match_credit_card_payment(user, updated_transaction)
        rebuild_balances(user, updated_transaction.account_id)

        if old_account_id && old_account_id != updated_transaction.account_id do
          rebuild_balances(user, old_account_id)
        end

        {:ok, updated_transaction}

      error ->
        error
    end
  end

  @doc """
  Quickly updates the category of one of the user's transactions by ID.

  `{:error, :not_found}` when the transaction is not the user's; a category that
  is not the user's is a changeset error on `:category_id`.
  """
  def update_transaction_category(%User{} = user, id, category_id) do
    case fetch_owned(Transaction, user, id) do
      nil -> {:error, :not_found}
      transaction -> do_update_transaction_category(user, transaction, category_id)
    end
  end

  defp do_update_transaction_category(user, transaction, category_id) do
    extra =
      case category_id && fetch_owned(Category, user, category_id) do
        %Category{default_reimbursable: true} when is_nil(transaction.reimbursement_status) ->
          %{reimbursement_status: "pending"}

        _ ->
          %{}
      end

    transaction
    |> Ecto.Changeset.cast(Map.merge(%{category_id: category_id}, extra), [
      :category_id,
      :reimbursement_status
    ])
    |> Ownership.validate_owned(:category_id, Category)
    |> Ecto.Changeset.foreign_key_constraint(:category_id)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        maybe_match_credit_card_payment(user, updated)
        rebuild_balances(user, updated.account_id)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Deletes one of the user's transactions; `{:error, :not_found}` (and no
  change) for anyone else's.
  """
  def delete_transaction(%User{} = user, %Transaction{} = transaction) do
    delete_owned(Transaction, user, transaction)
    |> case do
      {:ok, deleted} ->
        rebuild_balances(user, deleted.account_id)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Deletes all of the user's transactions.
  """
  def delete_all_transactions(%User{} = user) do
    active_accounts = CashLens.Accounts.list_active_accounts(user)
    res = Repo.delete_all(Ownership.scope(Transaction, user))

    Enum.each(active_accounts, fn account ->
      rebuild_balances(user, account.id)
    end)

    res
  end

  @doc """
  Reapplies auto-categorization rules to all of the user's transactions without a category.
  """
  def reapply_auto_categorization(%User{} = user) do
    query = from t in Ownership.scope(Transaction, user), where: is_nil(t.category_id)
    pending_transactions = Repo.all(query)

    Enum.each(pending_transactions, &process_auto_categorization_reapply(user, &1))

    :ok
  end

  @doc """
  Reapplies transfer rules to all of the user's unmatched transactions and attempts matching.
  """
  def reapply_transfer_rules(%User{} = user) do
    transfer_cat_id = get_transfer_category_id(user)

    transfer_count_before = count_with_category(user, transfer_cat_id)

    unmatched = unmatched_transfer_key_transactions(user)

    Enum.each(unmatched, &TransferRuleApplier.maybe_apply_rule(user, &1))

    unmatched_after = unmatched_transfer_key_transactions(user)

    TransferMatcher.match_transfers(user, unmatched_after)

    retry_credit_card_matching(user)

    # Rebuild balances for all active accounts after applying rules
    Enum.each(
      CashLens.Accounts.list_active_accounts(user),
      fn account ->
        rebuild_balances(user, account.id)
      end
    )

    transfer_count_after = count_with_category(user, transfer_cat_id)

    {:ok, transfer_count_after - transfer_count_before}
  end

  defp unmatched_transfer_key_transactions(user) do
    Repo.all(from t in Ownership.scope(Transaction, user), where: is_nil(t.transfer_key))
  end

  defp count_with_category(_user, nil), do: 0

  defp count_with_category(user, category_id) do
    Repo.aggregate(
      from(t in Ownership.scope(Transaction, user), where: t.category_id == ^category_id),
      :count
    )
  end

  defp get_transfer_category_id(user) do
    case Categories.get_category_by_slug(user, "transfer") do
      nil -> nil
      cat -> cat.id
    end
  end

  defp retry_credit_card_matching(user) do
    case get_credit_card_category_id(user) do
      nil ->
        :ok

      cc_id ->
        linked_parent_ids =
          from(c in Ownership.scope(Transaction, user),
            where: not is_nil(c.parent_transaction_id),
            select: c.parent_transaction_id,
            distinct: true
          )

        from(t in Ownership.scope(Transaction, user),
          where: t.category_id == ^cc_id,
          where: t.id not in subquery(linked_parent_ids)
        )
        |> Repo.all()
        |> Enum.each(&CreditCardMatcher.match_payment(user, &1))
    end
  end

  defp process_auto_categorization_reapply(user, tx) do
    updates = AutoCategorizer.categorize(user, tx)
    if updates.category_id, do: do_update_category_and_match(user, tx.id, updates.category_id)
  end

  defp do_update_category_and_match(user, tx_id, category_id) do
    case update_transaction_category(user, tx_id, category_id) do
      {:ok, updated_tx} ->
        affected_ids = maybe_apply_transfer_matching(user, updated_tx, category_id)

        [updated_tx.account_id | affected_ids]
        |> Enum.uniq()
        |> Enum.each(&rebuild_balances(user, &1))

      _ ->
        :ok
    end
  end

  defp maybe_apply_transfer_matching(user, updated_tx, category_id) do
    if category_id == get_transfer_category_id(user) do
      mirrors = TransferRuleApplier.maybe_apply_rule(user, updated_tx)
      mirror_ids = Enum.map(mirrors, & &1.account_id)

      twin_ids =
        case TransferMatcher.match_transfer(user, updated_tx) do
          {:ok, twin_account_id} -> [twin_account_id]
          _ -> []
        end

      mirror_ids ++ twin_ids
    else
      []
    end
  end

  defp get_credit_card_category_id(user) do
    case Categories.get_category_by_slug(user, "cartao-de-credito") do
      nil -> nil
      category -> category.id
    end
  end

  defp maybe_match_credit_card_payment(user, %Transaction{} = tx) do
    cc_id = get_credit_card_category_id(user)

    if cc_id && tx.category_id == cc_id do
      CreditCardMatcher.match_payment(user, tx)
    end

    :ok
  end

  @doc """
  Unlinks all of the user's transactions sharing the same reimbursement_link_key.

  `{:error, :not_found}` when none of the user's transactions carries the key.
  """
  def unlink_reimbursement_by_key(%User{}, nil), do: :ok

  def unlink_reimbursement_by_key(%User{} = user, link_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # 1. Restore negative transactions (expenses) to 'pending'
    {expenses, _} =
      from(t in Ownership.scope(Transaction, user),
        where: t.reimbursement_link_key == ^link_key and t.amount < 0
      )
      |> Repo.update_all(
        set: [
          reimbursement_status: "pending",
          reimbursement_link_key: nil,
          updated_at: now
        ]
      )

    # 2. Clear positive transactions (credits) completely
    {credits, _} =
      from(t in Ownership.scope(Transaction, user),
        where: t.reimbursement_link_key == ^link_key and t.amount > 0
      )
      |> Repo.update_all(
        set: [
          reimbursement_status: nil,
          reimbursement_link_key: nil,
          updated_at: now
        ]
      )

    if expenses + credits == 0, do: {:error, :not_found}, else: :ok
  end

  @doc """
  Rejects a reimbursement pair so it won't be suggested again.

  Both transactions must be the user's: `{:error, :not_found}` otherwise.
  """
  def reject_reimbursement_pair(%User{} = user, tx_id_a, tx_id_b) do
    if all_owned?(user, [tx_id_a, tx_id_b]) do
      %RejectedReimbursementPair{user_id: user.id}
      |> RejectedReimbursementPair.changeset(%{
        transaction_a_id: tx_id_a,
        transaction_b_id: tx_id_b
      })
      |> Repo.insert()
    else
      {:error, :not_found}
    end
  end

  @doc """
  Given a list of transfer_keys, returns a map %{transfer_key => [tx, tx]}
  with both sides of each pair preloaded with account.
  """
  def get_transfer_pairs(%User{}, []), do: %{}

  def get_transfer_pairs(%User{} = user, transfer_keys) do
    from(t in Ownership.scope(Transaction, user),
      where: t.transfer_key in ^transfer_keys,
      preload: ^owned_preloads(user, [:account])
    )
    |> Repo.all()
    |> Enum.group_by(& &1.transfer_key)
  end

  @doc """
  Returns `%{reimbursement_link_key => [transaction]}` for the given link keys,
  so a row can name (and open) the transaction on the other side of its
  reimbursement — the expense from the deposit credit and vice-versa.
  """
  def get_reimbursement_pairs(%User{}, []), do: %{}

  def get_reimbursement_pairs(%User{} = user, link_keys) do
    from(t in Ownership.scope(Transaction, user),
      where: t.reimbursement_link_key in ^link_keys,
      order_by: [asc: t.amount, asc: t.id],
      preload: ^owned_preloads(user, [:account])
    )
    |> Repo.all()
    |> Enum.group_by(& &1.reimbursement_link_key)
  end

  @doc """
  Returns the count of the user's transactions without a category.
  """
  def count_pending_transactions(%User{} = user) do
    Repo.aggregate(
      from(t in Ownership.scope(Transaction, user), where: is_nil(t.category_id)),
      :count
    )
  end

  @doc """
  Returns the "statement health" metrics shown on the transactions screen when
  no filter is active: how many rows still lack a category, how much money is
  still expected back from reimbursable expenses, and how many transactions
  categorized as transfers have no matching counterpart yet.

  All three are single aggregate queries so the bar stays cheap to render on
  every stream refresh.
  """
  def statement_health(%User{} = user) do
    %{
      uncategorized_count: count_pending_transactions(user),
      reimbursements_receivable_count: count_reimbursements_receivable(user),
      reimbursements_receivable_total: total_reimbursements_receivable(user),
      unmatched_transfers_count: count_unmatched_transfers(user)
    }
  end

  defp reimbursements_receivable(queryable) do
    queryable
    |> where([t], is_nil(t.reimbursement_link_key))
    |> where([t], t.amount < 0)
    |> where([t], t.reimbursement_status in ["pending", "requested"])
  end

  defp count_reimbursements_receivable(user) do
    Transaction
    |> Ownership.scope(user)
    |> reimbursements_receivable()
    |> Repo.aggregate(:count)
  end

  defp total_reimbursements_receivable(user) do
    total =
      Transaction
      |> Ownership.scope(user)
      |> reimbursements_receivable()
      |> select([t], sum(fragment("ABS(?)", t.amount)))
      |> Repo.one()

    total || Decimal.new("0")
  end

  defp count_unmatched_transfers(user) do
    categories = owned_query(:category, user)

    from(t in Ownership.scope(Transaction, user),
      join: c in ^categories,
      on: c.id == t.category_id,
      where: is_nil(t.transfer_key),
      where: c.slug == "transfer"
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns suggested transfer pairs: opposite amounts on different accounts whose
  dates fall within #{@transfer_pairing_window_days} days of each other, both
  unmatched and both either uncategorized or categorized as 'transfer'.

  Each transaction takes part in at most one suggestion: candidate pairs are
  ranked by how close their dates are (then by recency) and greedily assigned.
  Returns a list of {tx_out, tx_in} tuples sorted by date desc.
  """
  def list_transfer_suggestions(%User{} = user) do
    transfer_cat = Categories.get_category_by_slug(user, "transfer")
    transfer_cat_id = transfer_cat && transfer_cat.id

    transfer_suggestion_candidates(user, transfer_cat_id)
    |> pick_disjoint_pairs()
    |> Enum.map(&order_transfer_pair(user, &1))
  end

  defp transfer_suggestion_candidates(user, transfer_cat_id) do
    window = @transfer_pairing_window_days
    # A user without a transfer category only matches uncategorized rows.
    transfer_ids = List.wrap(transfer_cat_id)
    accounts = owned_query(:account, user)
    transactions = Ownership.scope(Transaction, user)

    from(a in transactions,
      join: acct_a in ^accounts,
      on: acct_a.id == a.account_id,
      as: :acct_a,
      join: b in ^transactions,
      on:
        fragment("ABS(? - ?) <= ?", a.date, b.date, ^window) and
          a.amount == fragment("? * -1", b.amount) and
          a.account_id != b.account_id and
          a.id < b.id,
      join: acct_b in ^accounts,
      on: acct_b.id == b.account_id,
      as: :acct_b,
      where: is_nil(a.transfer_key) and is_nil(b.transfer_key),
      where:
        (is_nil(a.category_id) or a.category_id in ^transfer_ids) and
          (is_nil(b.category_id) or b.category_id in ^transfer_ids),
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Scopes.cash_account_binding(:acct_a)
    |> Scopes.cash_account_binding(:acct_b)
    |> Repo.all()
  end

  # Greedily keeps the best candidate pair for each transaction: the closest
  # dates win, ties broken by the most recent pair, so a transaction never shows
  # up in two suggestions at once.
  defp pick_disjoint_pairs(candidates) do
    candidates
    |> Enum.sort_by(fn {a, b} ->
      {abs(Date.diff(a.date, b.date)), Date.diff(~D[0000-01-01], a.date)}
    end)
    |> Enum.reduce({[], MapSet.new()}, fn {a, b}, {kept, used} ->
      if MapSet.member?(used, a.id) or MapSet.member?(used, b.id) do
        {kept, used}
      else
        {[{a, b} | kept], used |> MapSet.put(a.id) |> MapSet.put(b.id)}
      end
    end)
    |> elem(0)
    |> Enum.sort_by(fn {a, _b} -> a.date end, {:desc, Date})
  end

  # Preloads both sides of a suggested transfer pair and orders them so the
  # debit (negative amount) comes first.
  defp order_transfer_pair(user, {a, b}) do
    a = preload_owned(a, user, [:account, :category])
    b = preload_owned(b, user, [:account, :category])
    if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
  end

  @doc """
  Returns unmatched transfers (transfer category, no transfer_key) that have
  no auto-suggestion pair.

  Callers that already hold the output of `list_transfer_suggestions/1` can pass
  it in to avoid recomputing the pairing query.
  """
  def list_unmatched_transfers_without_suggestion(%User{} = user, suggestions \\ nil) do
    transfer_cat = Categories.get_category_by_slug(user, "transfer")

    if is_nil(transfer_cat) do
      []
    else
      suggested_ids =
        (suggestions || list_transfer_suggestions(user))
        |> Enum.flat_map(fn {out, inc} -> [out.id, inc.id] end)

      from(t in Ownership.scope(Transaction, user),
        where: is_nil(t.transfer_key),
        where: t.category_id == ^transfer_cat.id,
        where: t.id not in ^suggested_ids,
        order_by: [desc: t.date],
        preload: ^owned_preloads(user, [:account, :category])
      )
      |> Scopes.cash_accounts_only(user)
      |> Repo.all()
    end
  end

  @doc """
  Returns manual-link candidates for `transaction`: opposite-sign, unmatched
  transactions on other accounts within
  #{@transfer_link_window_days} days, each annotated with the absolute amount
  difference and the number of days between the two dates.

  Sorted by amount difference, then by day difference, so the closest match
  comes first. A transaction that is not the user's has no candidates.
  """
  def list_transfer_link_candidates(%User{} = user, %Transaction{} = transaction) do
    case fetch_owned(Transaction, user, transaction.id) do
      nil -> []
      transaction -> do_list_transfer_link_candidates(user, transaction)
    end
  end

  defp do_list_transfer_link_candidates(user, transaction) do
    transfer_cat = Categories.get_category_by_slug(user, "transfer")
    transfer_cat_id = transfer_cat && transfer_cat.id
    transfer_ids = List.wrap(transfer_cat_id)
    opposite_sign = if Decimal.negative?(transaction.amount), do: :positive, else: :negative

    from(t in Ownership.scope(Transaction, user),
      where: t.id != ^transaction.id,
      where: t.account_id != ^transaction.account_id,
      where: is_nil(t.transfer_key),
      where: is_nil(t.category_id) or t.category_id in ^transfer_ids,
      where: fragment("ABS(? - ?) <= ?", t.date, ^transaction.date, ^@transfer_link_window_days),
      preload: ^owned_preloads(user, [:account])
    )
    |> Scopes.cash_accounts_only(user)
    |> Repo.all()
    |> Enum.filter(&matching_sign?(&1.amount, opposite_sign))
    |> Enum.map(fn candidate ->
      %{
        transaction: candidate,
        amount_diff: candidate.amount |> Decimal.add(transaction.amount) |> Decimal.abs(),
        day_diff: abs(Date.diff(candidate.date, transaction.date))
      }
    end)
    |> Enum.sort_by(&{Decimal.to_float(&1.amount_diff), &1.day_diff})
    |> Enum.take(@transfer_link_candidate_limit)
  end

  defp matching_sign?(amount, :positive), do: Decimal.positive?(amount)
  defp matching_sign?(amount, :negative), do: Decimal.negative?(amount)

  @doc """
  Creates the mirror of `transaction_id` on `destination_account_id` — the
  symmetric transaction that was never imported — and links both rows as a
  transfer pair.

  Both the transaction and the destination account must be the user's:
  `{:error, :not_found}` otherwise, with nothing written.

  Returns `{:error, :same_account}` when the destination is the origin account,
  and `{:error, :already_linked}` when the transaction already belongs to a pair.
  """
  def create_mirror_transaction(%User{} = user, transaction_id, destination_account_id) do
    origin = fetch_owned(Transaction, user, transaction_id)
    destination = fetch_owned(Account, user, destination_account_id)

    cond do
      is_nil(origin) or is_nil(destination) ->
        {:error, :not_found}

      origin.account_id == destination.id ->
        {:error, :same_account}

      not is_nil(origin.transfer_key) ->
        {:error, :already_linked}

      true ->
        insert_mirror(user, origin, destination.id)
    end
  end

  defp insert_mirror(user, origin, destination_account_id) do
    transfer_cat = Categories.get_category_by_slug(user, "transfer")
    transfer_key = Ecto.UUID.generate()

    attrs = %{
      account_id: destination_account_id,
      category_id: transfer_cat && transfer_cat.id,
      date: origin.date,
      description: origin.description,
      amount: Decimal.negate(origin.amount),
      source: "manual",
      transfer_key: transfer_key
    }

    case %Transaction{user_id: user.id} |> Transaction.changeset(attrs) |> Repo.insert() do
      {:ok, mirror} ->
        {:ok, _} =
          origin
          |> Transaction.changeset(%{
            transfer_key: transfer_key,
            category_id: attrs.category_id || origin.category_id
          })
          |> Repo.update()

        rebuild_balances(user, destination_account_id)

        {:ok, preload_owned(mirror, user, [:account, :category])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns all of the user's linked transfer pairs as {tx_out, tx_in} tuples, sorted by date desc.
  """
  def list_linked_transfer_pairs(%User{} = user) do
    transactions = Ownership.scope(Transaction, user)

    from(a in transactions,
      join: b in ^transactions,
      on: a.transfer_key == b.transfer_key and a.id < b.id,
      where: not is_nil(a.transfer_key),
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.map(fn {a, b} ->
      a = preload_owned(a, user, [:account])
      b = preload_owned(b, user, [:account])
      if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
    end)
  end

  @doc """
  Returns suggested reimbursement pairs: same absolute amount, date within 15 days,
  both unmatched, where the debit is marked as 'pending' or 'requested' for reimbursement,
  and the credit is not a transfer/initial value.
  Returns a list of {expense, credit} tuples sorted by date desc.
  """
  def list_reimbursement_suggestions(%User{} = user) do
    excluded_ids = excluded_reimbursement_category_ids(user)

    reimbursement_suggestions(user, excluded_ids)
    |> Enum.filter(fn {a, b} ->
      {expense, credit} = if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
      diff = Date.diff(credit.date, expense.date)

      diff >= 0 and diff <= 15 and
        is_nil(a.transfer_key) and is_nil(b.transfer_key) and
        a.reimbursement_status != "paid" and b.reimbursement_status != "paid"
    end)
    |> Enum.map(&order_reimbursement_pair(user, &1))
  end

  defp reimbursement_suggestions(user, excluded_ids) do
    accounts = owned_query(:account, user)
    transactions = Ownership.scope(Transaction, user)
    rejected = Ownership.scope(RejectedReimbursementPair, user)

    from(a in transactions,
      join: b in ^transactions,
      on:
        a.amount == fragment("? * -1", b.amount) and
          a.id < b.id,
      join: acc_a in ^accounts,
      on: acc_a.id == a.account_id,
      join: acc_b in ^accounts,
      on: acc_b.id == b.account_id,
      left_join: rp in ^rejected,
      on: rp.transaction_a_id == a.id and rp.transaction_b_id == b.id,
      where: is_nil(rp.id),
      where: is_nil(a.reimbursement_link_key) and is_nil(b.reimbursement_link_key),
      where: is_nil(a.category_id) or a.category_id not in ^excluded_ids,
      where: is_nil(b.category_id) or b.category_id not in ^excluded_ids,
      where: acc_a.accepts_import == true and acc_b.accepts_import == true,
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Repo.all()
  end

  defp excluded_reimbursement_category_ids(user) do
    category_ids_with_children(user, @excluded_reimbursement_slugs)
  end

  defp order_reimbursement_pair(user, {a, b}) do
    a = preload_owned(a, user, [:account, :category])
    b = preload_owned(b, user, [:account, :category])
    if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
  end

  @doc """
  Returns the user's unmatched reimbursement expenses (pending or requested) that have no auto-suggestion pair.
  """
  def list_unmatched_reimbursements_without_suggestion(%User{} = user) do
    suggestions = list_reimbursement_suggestions(user)

    suggested_ids =
      Enum.flat_map(suggestions, fn {a, b} -> [a.id, b.id] end)
      |> MapSet.new()

    from(t in Ownership.scope(Transaction, user),
      where: is_nil(t.reimbursement_link_key),
      where: t.amount < 0,
      where: t.reimbursement_status in ["pending", "requested"],
      where: t.id not in ^MapSet.to_list(suggested_ids),
      order_by: [asc: t.date],
      preload: ^owned_preloads(user, [:account, :category])
    )
    |> Repo.all()
  end

  @doc """
  Returns all of the user's linked reimbursement pairs as {expense, credit} tuples, sorted by date desc.
  """
  def list_linked_reimbursement_pairs(%User{} = user) do
    transactions = Ownership.scope(Transaction, user)

    from(a in transactions,
      join: b in ^transactions,
      on: a.reimbursement_link_key == b.reimbursement_link_key and a.id < b.id,
      where: not is_nil(a.reimbursement_link_key),
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.map(fn {a, b} ->
      a = preload_owned(a, user, [:account, :category])
      b = preload_owned(b, user, [:account, :category])
      if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
    end)
  end

  @doc """
  Links a group of expenses and credits under a single reimbursement link key, setting all of them to the same category_id.

  Every transaction (and the category, when given) must be the user's: if any
  is not, `{:error, :not_found}` is returned and nothing changes.
  """
  def link_reimbursement_group(%User{} = user, expense_ids, credit_ids, category_id) do
    link_key = Ecto.UUID.generate()

    cond do
      not all_owned?(user, expense_ids ++ credit_ids) ->
        {:error, :not_found}

      not is_nil(category_id) and is_nil(fetch_owned(Category, user, category_id)) ->
        {:error, :not_found}

      true ->
        Repo.transaction(fn ->
          link = &link_reimbursement_leg(user, &1, link_key, category_id)
          {Enum.map(expense_ids, link), Enum.map(credit_ids, link)}
        end)
    end
  end

  defp link_reimbursement_leg(user, id, link_key, category_id) do
    tx = get_transaction!(user, id)

    {:ok, updated} =
      update_transaction(user, tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        category_id: category_id
      })

    updated
  end

  @doc """
  Links an expense and a credit transaction as a reimbursement.

  `{:error, :not_found}` unless both are the user's.
  """
  def link_reimbursement_pair(%User{} = user, expense_id, credit_id, category_id \\ nil) do
    with %Transaction{} = expense <- fetch_owned(Transaction, user, expense_id),
         %Transaction{} = credit <- fetch_owned(Transaction, user, credit_id) do
      final_category_id = category_id || expense.category_id || credit.category_id

      case link_reimbursement_group(user, [expense_id], [credit_id], final_category_id) do
        {:ok, {[updated_expense], [updated_credit]}} ->
          {:ok, {updated_expense, updated_credit}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Links two of the user's transactions as a transfer pair and ensures both are
  categorized as 'transfer'.

  `{:error, :not_found}` (and no change) unless both are the user's.
  """
  def link_transfer_pair(%User{} = user, tx_id_a, tx_id_b) do
    if all_owned?(user, [tx_id_a, tx_id_b]) do
      link_key = Ecto.UUID.generate()

      transfer_cat = Categories.get_category_by_slug(user, "transfer")

      cat_id = transfer_cat && transfer_cat.id
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.transaction(fn ->
        from(t in Ownership.scope(Transaction, user), where: t.id in [^tx_id_a, ^tx_id_b])
        |> Repo.update_all(set: [transfer_key: link_key, category_id: cat_id, updated_at: now])
      end)

      {:ok, link_key}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Unlinks a transfer pair by clearing the transfer_key from both transactions.

  `{:error, :not_found}` when none of the user's transactions carries the key.
  """
  def unlink_transfer_pair(%User{} = user, transfer_key) do
    {:ok, {count, _}} =
      Repo.transaction(fn ->
        from(t in Ownership.scope(Transaction, user), where: t.transfer_key == ^transfer_key)
        |> Repo.update_all(
          set: [
            transfer_key: nil,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )
      end)

    if count == 0, do: {:error, :not_found}, else: {:ok, {count, nil}}
  end

  @doc """
  Suggests an installment group and next installment number for a transaction.

  Nothing is suggested for a transaction that is not the user's, nor from a
  group the user does not own.
  """
  def suggest_installment_link(%User{id: user_id}, %Transaction{user_id: owner_id})
      when owner_id != user_id,
      do: nil

  def suggest_installment_link(%User{id: user_id} = user, %Transaction{} = tx) do
    case CashLens.Installments.find_matching_group(user, tx.description) do
      %{user_id: ^user_id} = group ->
        progress = CashLens.Installments.get_group_with_progress(user, group.id)

        if progress.is_completed do
          nil
        else
          %{
            group_id: group.id,
            group_name: group.description_pattern,
            next_installment: progress.paid_count + 1,
            total_installments: group.installments
          }
        end

      _ ->
        nil
    end
  end

  def change_transaction(%Transaction{} = transaction, attrs \\ %{}),
    do: Transaction.changeset(transaction, attrs)

  @spend_rate_months 6

  @doc """
  How fast money is leaving this month, against how fast it usually leaves.

  The month's total answers nothing on the 9th: eight thousand spent is a
  disaster in a week and a quiet month in four. The rate per elapsed day is
  comparable from the first day of the month, which is when the number is
  worth acting on.

  It reads the same history the Despesas figure does -- cash accounts only,
  transfers, initial values and both legs of a reimbursement excluded -- so the
  rate is money that really left, and the comparison is like for like.

  The divisor is the days the ledger actually covers, not the days the calendar
  has run. Dividing by the calendar turns an unimported week into good news: on
  11/10/2026 the statement stopped at the 5th, so six days of spending were
  spread over eleven days and the card read 771,11/dia, a reassuring 30% under
  the average, when the covered days gave 1.696,44 -- a quarter *above* it. The
  arrow pointed the wrong way for want of data, which is the one direction a
  warning must never point.

  Options: `:months` (the baseline length) and `:excluded_category_ids`, passed
  through to `get_historical_summary/2`.

  The average deliberately spans whole months only. A month still running
  would drag the baseline towards whatever today happens to be, which is the
  very thing being measured.
  """
  def spend_rate(user, month, expenses, today \\ Date.utc_today(), opts \\ [])

  def spend_rate(%User{} = user, %Date{} = month, expenses, %Date{} = today, opts) do
    months = Keyword.get(opts, :months, @spend_rate_months)

    previous =
      opts
      |> Keyword.take([:excluded_category_ids])
      |> Keyword.put(:limit, months + 2)
      |> then(&get_historical_summary(user, &1))
      |> Enum.filter(&earlier_month?(&1, month))
      |> Enum.take(-months)

    {total, days} =
      Enum.reduce(previous, {Decimal.new(0), 0}, fn row, {total, days} ->
        {Decimal.add(total, row.expenses),
         days + Date.days_in_month(Date.new!(row.year, row.month, 1))}
      end)

    per_day = per_day(expenses, covered_days(user, month, today))
    average = per_day(total, days)

    %{
      per_day: per_day,
      average: average,
      delta: delta(per_day, average),
      months: length(previous)
    }
  end

  defp earlier_month?(%{year: year, month: month}, %Date{} = reference),
    do: {year, month} < {reference.year, reference.month}

  # A month already past ran all the way to its end. A month still running ran
  # only as far as the ledger reaches -- the last movement dated on or before
  # today, whatever it was. A transfer is not spending, but it is still proof
  # that the statement was imported that far, which is the only thing being
  # asked here.
  #
  # Dated on or before today, because a few rows sit in the future: month-end
  # "Rendimento" lines are posted ahead, and a plain `max(date)` would read
  # 31/10 as the ledger's reach on the 11th and halve the rate.
  #
  # With nothing imported this month yet there is no covered day, and the one
  # day floor keeps the division defined; the figure it produces is the month's
  # whole spending, which is the honest reading of a single covered day.
  defp covered_days(
         user,
         %Date{year: year, month: month} = first,
         %Date{year: year, month: month} = today
       ) do
    case last_movement_on_or_before(user, first, today) do
      nil -> 1
      %Date{} = last -> max(Date.diff(last, first) + 1, 1)
    end
  end

  defp covered_days(_user, %Date{} = month, _today), do: Date.days_in_month(month)

  defp last_movement_on_or_before(user, first, today) do
    Transaction
    |> Ownership.scope(user)
    |> Scopes.cash_accounts_only(user)
    |> where([t], t.date >= ^first and t.date <= ^today)
    |> select([t], max(t.date))
    |> Repo.one()
  end

  # Rebuilds the balances of one of the user's accounts.
  defp rebuild_balances(user, account_id) do
    CashLens.Accounting.rebuild_account_balances(user, account_id)
  end

  defp per_day(_total, 0), do: Decimal.new("0")
  defp per_day(total, days), do: Decimal.div(total, days)

  # Without a baseline there is nothing to compare to, and saying "+100%"
  # against zero would be a claim the history does not support.
  defp delta(per_day, average) do
    if Decimal.equal?(average, 0) do
      nil
    else
      per_day |> Decimal.sub(average) |> Decimal.div(average)
    end
  end
end
