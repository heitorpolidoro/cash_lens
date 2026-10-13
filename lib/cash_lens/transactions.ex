defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Accounts.Scopes
  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.CreditCards.Matcher, as: CreditCardMatcher
  alias CashLens.Repo
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.BulkIgnorePattern
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.RejectedReimbursementPair
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.TransferRule
  alias CashLens.Transactions.TransferRuleApplier

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
  Rows returned per page by `list_transactions/3`. Exposed so the transactions
  LiveView can tell a full page (there may be more) from a short one (the
  infinite scroll reached the end) without hardcoding the same number twice.
  """
  def default_page_size, do: @default_page_size

  @doc """
  Returns the list of all transfer rules, preloading source and destination accounts.
  """
  def list_transfer_rules do
    Repo.all(
      from r in TransferRule,
        order_by: [asc: r.inserted_at],
        preload: [:source_account, :destination_account]
    )
  end

  def get_transfer_rule!(id) do
    Repo.get!(TransferRule, id) |> Repo.preload([:source_account, :destination_account])
  end

  def create_transfer_rule(attrs \\ %{}) do
    %TransferRule{}
    |> TransferRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_transfer_rule(%TransferRule{} = rule, attrs) do
    rule
    |> TransferRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_transfer_rule(%TransferRule{} = rule) do
    Repo.delete(rule)
  end

  def change_transfer_rule(%TransferRule{} = rule, attrs \\ %{}) do
    TransferRule.changeset(rule, attrs)
  end

  @doc """
  Returns the list of all bulk ignore patterns.
  """
  def list_bulk_ignore_patterns do
    Repo.all(from b in BulkIgnorePattern, order_by: [asc: b.pattern])
  end

  def list_transactions_by_description(description) do
    Repo.all(
      from t in Transaction,
        where: t.description == ^description,
        order_by: [desc: t.date]
    )
  end

  def create_bulk_ignore_pattern(attrs \\ %{}) do
    %BulkIgnorePattern{}
    |> BulkIgnorePattern.changeset(attrs)
    |> Repo.insert()
  end

  def update_bulk_ignore_pattern(%BulkIgnorePattern{} = pattern, attrs) do
    pattern
    |> BulkIgnorePattern.changeset(attrs)
    |> Repo.update()
  end

  def delete_bulk_ignore_pattern(%BulkIgnorePattern{} = pattern) do
    Repo.delete(pattern)
  end

  def change_bulk_ignore_pattern(%BulkIgnorePattern{} = pattern, attrs \\ %{}) do
    BulkIgnorePattern.changeset(pattern, attrs)
  end

  def get_bulk_ignore_pattern!(id), do: Repo.get!(BulkIgnorePattern, id)

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
  def get_filtered_summary(filters \\ %{}) do
    base =
      Transaction
      |> filter_by_account(filters["account_id"])
      |> filter_by_category(filters["category_id"])
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
      |> filter_unmatched_transfers(filters["unmatched_transfers"])
      |> exclude_transfer_category()
      |> join(:left, [t], a in assoc(t, :account), as: :summary_account)
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
  The zeroed shape `get_filtered_summary/1` returns, with both groups present.
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

  def count_transactions(filters \\ %{}) do
    Transaction
    |> join_associations()
    |> filter_by_account(filters["account_id"])
    |> filter_by_category(filters["category_id"])
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
    |> filter_unmatched_transfers(filters["unmatched_transfers"])
    |> Repo.aggregate(:count)
  end

  def list_transactions(filters \\ %{}, page \\ 1, page_size \\ @default_page_size) do
    offset = (page - 1) * page_size
    sort_order = String.to_existing_atom(filters["sort_order"] || "desc")

    Transaction
    |> join_associations()
    |> filter_by_account(filters["account_id"])
    |> filter_by_category(filters["category_id"])
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
    |> filter_unmatched_transfers(filters["unmatched_transfers"])
    |> order_by_date(sort_order)
    |> limit(^page_size)
    |> offset(^offset)
    |> Repo.all()
    |> CategorySuggester.annotate()
  end

  @excluded_reimbursement_slugs [
    "transfer",
    "initial_value",
    "salário",
    "salario",
    "cartao-de-credito"
  ]

  def list_reimbursement_credit_candidates(search \\ "") do
    excluded_ids =
      Enum.flat_map(@excluded_reimbursement_slugs, fn slug ->
        case Repo.one(
               from c in CashLens.Categories.Category, where: c.slug == ^slug, select: c.id
             ) do
          nil ->
            []

          id ->
            CashLens.Categories.get_category_ids_with_children(
              CashLens.Ownership.current_user!(),
              id
            )
        end
      end)
      |> Enum.uniq()

    from(t in Transaction,
      join: acct in assoc(t, :account),
      left_join: c in assoc(t, :category),
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

  def list_all_transactions(filters \\ %{}) do
    sort_order = String.to_existing_atom(filters["sort_order"] || "desc")

    Transaction
    |> join_associations()
    |> filter_by_account(filters["account_id"])
    |> filter_by_category(filters["category_id"])
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
    |> filter_unmatched_transfers(filters["unmatched_transfers"])
    |> filter_cash_accounts_only(filters["cash_accounts_only"])
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
  defp filter_cash_accounts_only(query, flag) when flag in [true, "true"],
    do: Scopes.cash_accounts_only(query)

  defp filter_cash_accounts_only(query, _flag), do: query

  defp filter_unmatched_transfers(query, "true") do
    where(query, [t], t.transfer_key |> is_nil())
    |> join(:inner, [t], c in assoc(t, :category))
    |> where([..., c], c.slug == "transfer")
  end

  defp filter_unmatched_transfers(query, _), do: query

  # Excludes transactions categorized as transfers or credit-card payments
  # from income/expense aggregates (the itemized purchases still count, just
  # not the lump-sum payment — see spec section 8).
  defp exclude_transfer_category(query) do
    excluded_ids =
      ["transfer", "cartao-de-credito"]
      |> Enum.map(&Repo.one(from(c in Category, where: c.slug == ^&1, select: c.id)))
      |> Enum.reject(&is_nil/1)

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

  defp join_associations(query) do
    query
    |> preload([:category, :account, :installment_group])
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

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, ""), do: query

  defp filter_by_category(query, "nil") do
    where(query, [t], is_nil(t.category_id))
  end

  defp filter_by_category(query, category_id) do
    ids =
      CashLens.Categories.get_category_ids_with_children(
        CashLens.Ownership.current_user!(),
        category_id
      )

    where(query, [t], t.category_id in ^ids)
  end

  defp filter_by_description(query, nil), do: query
  defp filter_by_description(query, ""), do: query

  defp filter_by_description(query, search) do
    where(query, [t], ilike(t.description, ^"%#{search}%"))
  end

  @doc """
  Lists the most recent transactions with a limit.
  """
  def list_recent_transactions(limit \\ 5) do
    Repo.all(
      from t in Transaction,
        order_by: [desc: t.date, desc: t.inserted_at],
        limit: ^limit,
        preload: [:category, :account, :installment_group]
    )
  end

  @doc """
  Calculates monthly totals for income (positive) and expenses (negative), ignoring transfers.
  Considers only the cash-accounts scope (`CashLens.Accounts.Scopes`) unless a specific
  account_id filter is passed.
  Includes credit-card bill payments (cartao-de-credito) on bank accounts as cash expenses.

  `opts` may carry `:excluded_category_ids`, the list `summary_excluded_category_ids/0`
  returned, so a caller making several summary reads resolves it once. Without it
  the ids are resolved here.
  """
  def get_monthly_summary(date \\ nil, filters \\ %{}, opts \\ []) do
    filters = filters || %{}
    target_date = date || get_latest_transaction_date() || Date.utc_today()
    {first_of_month, last_of_month} = get_summary_period(target_date, filters)

    result =
      Transaction
      |> build_summary_base_query(excluded_ids(opts))
      |> apply_summary_date_filters(first_of_month, last_of_month, filters)
      |> apply_summary_account_filter(filters)
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
  `get_historical_summary/1` already assumes.

  Returns list of maps: %{name: str, category_id: binary, type: str, total: Decimal}
  sorted by total descending.
  """
  def get_month_category_breakdown(year, month) when is_integer(year) and is_integer(month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    categorized =
      from(t in Transaction,
        join: c in assoc(t, :category),
        left_join: p in assoc(c, :parent),
        left_join: g in assoc(p, :parent),
        where: t.date >= ^first and t.date <= ^last,
        where: t.amount < 0,
        # Transfers and opening balances are not spending. Credit-card bill
        # payments ARE, on this cash-basis screen: they are the cash leaving the
        # current account for the purchases the card already carried.
        where: c.id not in ^excluded_cash_summary_category_ids(),
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
      |> Scopes.cash_accounts_only()
      |> exclude_transactions_with_cash_children()
      |> Repo.all()
      |> Enum.map(fn row -> %{row | total: Decimal.abs(row.total)} end)

    uncategorized_total =
      from(t in Transaction,
        where: is_nil(t.category_id),
        where: t.amount < 0,
        where: t.date >= ^first and t.date <= ^last,
        where: is_nil(t.reimbursement_link_key),
        select: sum(fragment("ABS(?)", t.amount))
      )
      |> Scopes.cash_accounts_only()
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

  Mirrors `get_month_category_breakdown/2` but for net-positive (income)
  categories, and on the same cash basis: only accounts with
  `is_credit_card == false` count. The whole `cartao-de-credito` subtree stays
  excluded here — a credit in it is the mirror of a bill payment, never income —
  and so does every transaction carrying a `reimbursement_link_key`, whose
  credit leg only gives back what the paired expense took out.

  Returns list of maps: %{name, category_id, type, total} sorted by total descending.
  """
  def get_month_income_breakdown(year, month) when is_integer(year) and is_integer(month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    categorized =
      from(t in Transaction,
        join: c in assoc(t, :category),
        left_join: p in assoc(c, :parent),
        left_join: g in assoc(p, :parent),
        where: t.date >= ^first and t.date <= ^last,
        where: t.amount > 0,
        where: c.id not in ^excluded_report_category_ids(),
        # The credit leg of a reimbursement is not income: it gives back money
        # an expense of the same pair already took out. Only a link key marks an
        # actual pair (see `get_month_category_breakdown/2`).
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
      |> Scopes.cash_accounts_only()
      |> Repo.all()

    uncategorized_total =
      from(t in Transaction,
        where: is_nil(t.category_id),
        where: t.amount > 0,
        where: t.date >= ^first and t.date <= ^last,
        where: is_nil(t.reimbursement_link_key),
        select: sum(t.amount)
      )
      |> Scopes.cash_accounts_only()
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

  defp build_summary_base_query(query, excluded_ids) do
    from t in query,
      left_join: c in assoc(t, :category),
      where: is_nil(c.id) or c.id not in ^excluded_ids,
      where: is_nil(t.reimbursement_link_key)
  end

  defp apply_summary_date_filters(query, _first, _last, %{"category_id" => "nil"}), do: query

  defp apply_summary_date_filters(query, _first, _last, %{"unmatched_transfers" => "true"}),
    do: query

  defp apply_summary_date_filters(query, first, last, _filters) do
    where(query, [t], t.date >= ^first and t.date <= ^last)
  end

  defp apply_summary_account_filter(query, filters) do
    case Map.get(filters, "account_id") || Map.get(filters, :account_id) do
      account_id when account_id in [nil, ""] ->
        Scopes.cash_accounts_only(query)

      account_id ->
        where(query, [t], t.account_id == ^account_id)
    end
  end

  defp aggregate_summary_totals(query) do
    from(t in query,
      select: %{
        income: sum(fragment("CASE WHEN ? > 0 THEN ? ELSE 0 END", t.amount, t.amount)),
        expenses: sum(fragment("CASE WHEN ? < 0 THEN ABS(?) ELSE 0 END", t.amount, t.amount))
      }
    )
  end

  @doc """
  Returns pure income and expenses history grouped by month, excluding transfers.
  Considers only the cash-accounts scope (`CashLens.Accounts.Scopes`).

  Options: `:limit`, and `:excluded_category_ids` (see `get_monthly_summary/3`).
  """
  def get_historical_summary(opts \\ []) do
    limit = Keyword.get(opts, :limit)
    excluded_ids = excluded_ids(opts)

    cash_transactions = Scopes.cash_accounts_only(Transaction)

    query =
      from t in cash_transactions,
        left_join: c in assoc(t, :category),
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
  def get_historical_category_summary(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    res =
      query_historical_category_totals()
      |> Repo.all()
      |> Enum.group_by(&group_by_month_year/1)
      |> Enum.map(&format_month_summary/1)
      |> Enum.sort_by(fn %{year: y, month: m} -> {y, m} end, :desc)

    res = if limit, do: Enum.take(res, limit), else: res

    Enum.sort_by(res, fn %{year: y, month: m} -> {y, m} end)
  end

  defp query_historical_category_totals do
    from(t in Transaction,
      join: c in assoc(t, :category),
      left_join: p in assoc(c, :parent),
      where: t.amount < 0,
      # Category breakdown graphs: transfers and credit-card payments are not spending, so they are excluded.
      where: c.id not in ^excluded_report_category_ids(),
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
    |> exclude_transactions_with_children()
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
  def summary_excluded_category_ids, do: excluded_cash_summary_category_ids()

  defp excluded_ids(opts),
    do: Keyword.get_lazy(opts, :excluded_category_ids, &excluded_cash_summary_category_ids/0)

  defp excluded_cash_summary_category_ids do
    ["initial_value", "transfer"]
    |> Enum.map(&Categories.get_category_by_slug(CashLens.Ownership.current_user!(), &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(
      &Categories.get_category_ids_with_children(CashLens.Ownership.current_user!(), &1.id)
    )
    |> Enum.uniq()
  end

  # Category ids to exclude from every income/expense report: transfers, the
  # opening-balance placeholder, and the WHOLE "cartao-de-credito" subtree —
  # not just the exact parent slug. Bill payments are bookkeeping mirrors
  # between the user's own accounts/statements (the outgoing debit AND the
  # matching credit inside the card account), never real income or spending,
  # and they're just as often filed under a per-card child category (e.g.
  # "cartao-de-credito-pagamento", "cartao-de-credito-ourocard") as under the
  # bare parent slug.
  defp excluded_report_category_ids do
    ["initial_value", "transfer", "cartao-de-credito"]
    |> Enum.map(&Categories.get_category_by_slug(CashLens.Ownership.current_user!(), &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(
      &Categories.get_category_ids_with_children(CashLens.Ownership.current_user!(), &1.id)
    )
    |> Enum.uniq()
  end

  # Transactions that are themselves a parent (another transaction points its
  # parent_transaction_id at them) are excluded from category-spend
  # breakdowns: their amount is the lump sum of their children, who already
  # carry the real categories. See spec section 7.
  defp exclude_transactions_with_children(query) do
    linked_parent_ids =
      from(c in Transaction,
        where: not is_nil(c.parent_transaction_id),
        distinct: true,
        select: c.parent_transaction_id
      )

    where(query, [t], t.id not in subquery(linked_parent_ids))
  end

  # Cash-basis variant of `exclude_transactions_with_children/1`, used only by
  # `get_month_category_breakdown/2`. On that screen the children sitting on
  # credit-card accounts are invisible, so hiding their parent would drop the
  # amount from the month altogether — the card bill payment is exactly such a
  # parent. A parent is therefore hidden only when at least one of its children
  # is itself on a cash account and thus already reported here.
  defp exclude_transactions_with_cash_children(query) do
    linked_parent_ids =
      from(c in Transaction,
        where: not is_nil(c.parent_transaction_id),
        distinct: true,
        select: c.parent_transaction_id
      )
      |> Scopes.cash_accounts_only()

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
  Returns the most recent transaction date across every account, or `nil` if
  there are no transactions at all.
  """
  @spec get_latest_transaction_date() :: Date.t() | nil
  def get_latest_transaction_date do
    Repo.one(from t in Transaction, select: max(t.date))
  end

  @doc """
  Returns the most recent transaction date for `account_id`, or `nil` if the
  account has no transactions at all.

  Only permanently-persisted rows (`source` of `"file"` or `"manual"`) count.
  """
  @spec latest_transaction_date(Ecto.UUID.t()) :: Date.t() | nil
  def latest_transaction_date(account_id) do
    Repo.one(
      from t in Transaction,
        where: t.account_id == ^account_id and t.source in ["file", "manual"],
        select: max(t.date)
    )
  end

  @doc """
  Returns the most recent transaction date for `account_id` within `range`
  (inclusive), or `nil` if the account has no transaction in it.

  Only permanently-persisted rows (`source` of `"file"` or `"manual"`) count.
  """
  @spec latest_transaction_date_between(Ecto.UUID.t(), Date.t(), Date.t()) :: Date.t() | nil
  def latest_transaction_date_between(account_id, from_date, to_date) do
    Repo.one(
      from t in Transaction,
        where:
          t.account_id == ^account_id and t.source in ["file", "manual"] and
            t.date >= ^from_date and t.date <= ^to_date,
        select: max(t.date)
    )
  end

  @doc """
  Returns a map of `%{account_id => latest_date}` for all accounts having
  permanently-persisted transactions (`source` of `"file"` or `"manual"`).
  """
  @spec latest_transaction_dates() :: %{Ecto.UUID.t() => Date.t()}
  def latest_transaction_dates do
    from(t in Transaction,
      where: t.source in ["file", "manual"],
      group_by: t.account_id,
      select: {t.account_id, max(t.date)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Gets a single transaction.
  """
  def get_transaction!(id),
    do: Repo.get!(Transaction, id) |> Repo.preload([:category, :account, :installment_group])

  @doc """
  Creates a transaction (manual single-create path).

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
  """
  def create_transaction(attrs, opts \\ []) do
    attrs = maybe_allow_duplicate(attrs, Keyword.get(opts, :allow_duplicate, false))

    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} ->
        mirrors = TransferRuleApplier.maybe_apply_rule(transaction)

        twin_account_id =
          case TransferMatcher.match_transfer(transaction) do
            {:ok, id} -> id
            _ -> nil
          end

        maybe_match_credit_card_payment(transaction)

        # Rebuild balances for the original account
        CashLens.Accounting.rebuild_account_balances(transaction.account_id)

        # Rebuild balances for any mirror account
        Enum.each(mirrors, fn mirror ->
          CashLens.Accounting.rebuild_account_balances(mirror.account_id)
        end)

        # Rebuild balances for twin account if matched
        if twin_account_id do
          CashLens.Accounting.rebuild_account_balances(twin_account_id)
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
  Whether a transaction identical to `attrs` already exists -- same account,
  date, time, amount and normalized description.

  The question the manual-create form asks before writing a second one, and the
  reason it can ask at all: `dedup_key` is stored and indexed, so the existing
  charge is one lookup away.
  """
  def duplicate_of(attrs) do
    case identity_of(attrs) do
      nil ->
        nil

      %{dedup_key: key} ->
        from(t in Transaction,
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
  defp identity_of(attrs) do
    changeset = Transaction.changeset(%Transaction{}, attrs)

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
  defp maybe_allow_duplicate(attrs, false), do: attrs

  defp maybe_allow_duplicate(attrs, true) do
    case identity_of(attrs) do
      nil -> attrs
      %{attrs: identity} -> put_attr(attrs, :occurrence_index, next_occurrence_index(identity))
    end
  end

  defp next_occurrence_index(attrs, index \\ 0)

  defp next_occurrence_index(_attrs, index) when index >= @max_occurrence_index, do: index

  defp next_occurrence_index(attrs, index) do
    fingerprint = Transaction.fingerprint(attrs, index)

    if Repo.exists?(from(t in Transaction, where: t.fingerprint == ^fingerprint)) do
      next_occurrence_index(attrs, index + 1)
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
  Updates a transaction.
  """
  def update_transaction(%Transaction{} = transaction, attrs) do
    old_account_id = transaction.account_id

    transaction
    |> Transaction.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_transaction} ->
        maybe_match_credit_card_payment(updated_transaction)
        CashLens.Accounting.rebuild_account_balances(updated_transaction.account_id)

        if old_account_id && old_account_id != updated_transaction.account_id do
          CashLens.Accounting.rebuild_account_balances(old_account_id)
        end

        {:ok, updated_transaction}

      error ->
        error
    end
  end

  @doc """
  Quickly updates the category of a transaction by ID.
  """
  def update_transaction_category(id, category_id) do
    transaction = get_transaction!(id)

    extra =
      case category_id && Repo.get(Category, category_id) do
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
    |> Ecto.Changeset.foreign_key_constraint(:category_id)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        maybe_match_credit_card_payment(updated)
        CashLens.Accounting.rebuild_account_balances(updated.account_id)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Deletes a transaction.
  """
  def delete_transaction(%Transaction{} = transaction) do
    Repo.delete(transaction)
    |> case do
      {:ok, deleted} ->
        CashLens.Accounting.rebuild_account_balances(deleted.account_id)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Deletes all transactions from the database.
  """
  def delete_all_transactions do
    active_accounts = CashLens.Accounts.list_active_accounts(CashLens.Ownership.current_user!())
    res = Repo.delete_all(Transaction)

    Enum.each(active_accounts, fn account ->
      CashLens.Accounting.rebuild_account_balances(account.id)
    end)

    res
  end

  @doc """
  Reapplies auto-categorization rules to all transactions without a category.
  """
  def reapply_auto_categorization do
    query = from t in Transaction, where: is_nil(t.category_id)
    pending_transactions = Repo.all(query)

    Enum.each(pending_transactions, &process_auto_categorization_reapply/1)

    :ok
  end

  @doc """
  Reapplies transfer rules to all unmatched transactions and attempts matching.
  """
  def reapply_transfer_rules do
    transfer_cat_id = get_transfer_category_id()

    transfer_count_before =
      if transfer_cat_id,
        do:
          Repo.aggregate(from(t in Transaction, where: t.category_id == ^transfer_cat_id), :count),
        else: 0

    unmatched =
      Repo.all(
        from t in Transaction,
          where: is_nil(t.transfer_key)
      )

    Enum.each(unmatched, &TransferRuleApplier.maybe_apply_rule/1)

    unmatched_after =
      Repo.all(
        from t in Transaction,
          where: is_nil(t.transfer_key)
      )

    TransferMatcher.match_transfers(unmatched_after)

    retry_credit_card_matching()

    # Rebuild balances for all active accounts after applying rules
    Enum.each(
      CashLens.Accounts.list_active_accounts(CashLens.Ownership.current_user!()),
      fn account ->
        CashLens.Accounting.rebuild_account_balances(account.id)
      end
    )

    transfer_count_after =
      if transfer_cat_id,
        do:
          Repo.aggregate(from(t in Transaction, where: t.category_id == ^transfer_cat_id), :count),
        else: 0

    {:ok, transfer_count_after - transfer_count_before}
  end

  defp get_transfer_category_id do
    case CashLens.Categories.get_category_by_slug(CashLens.Ownership.current_user!(), "transfer") do
      nil -> nil
      cat -> cat.id
    end
  end

  defp retry_credit_card_matching do
    case get_credit_card_category_id() do
      nil ->
        :ok

      cc_id ->
        linked_parent_ids =
          from(c in Transaction,
            where: not is_nil(c.parent_transaction_id),
            select: c.parent_transaction_id,
            distinct: true
          )

        from(t in Transaction,
          where: t.category_id == ^cc_id,
          where: t.id not in subquery(linked_parent_ids)
        )
        |> Repo.all()
        |> Enum.each(&CreditCardMatcher.match_payment/1)
    end
  end

  defp process_auto_categorization_reapply(tx) do
    updates = AutoCategorizer.categorize(tx)
    if updates.category_id, do: do_update_category_and_match(tx.id, updates.category_id)
  end

  defp do_update_category_and_match(tx_id, category_id) do
    case update_transaction_category(tx_id, category_id) do
      {:ok, updated_tx} ->
        affected_ids = maybe_apply_transfer_matching(updated_tx, category_id)

        [updated_tx.account_id | affected_ids]
        |> Enum.uniq()
        |> Enum.each(&CashLens.Accounting.rebuild_account_balances/1)

      _ ->
        :ok
    end
  end

  defp maybe_apply_transfer_matching(updated_tx, category_id) do
    if category_id == get_transfer_category_id() do
      mirrors = TransferRuleApplier.maybe_apply_rule(updated_tx)
      mirror_ids = Enum.map(mirrors, & &1.account_id)

      twin_ids =
        case TransferMatcher.match_transfer(updated_tx) do
          {:ok, twin_account_id} -> [twin_account_id]
          _ -> []
        end

      mirror_ids ++ twin_ids
    else
      []
    end
  end

  defp get_credit_card_category_id do
    case CashLens.Categories.get_category_by_slug(
           CashLens.Ownership.current_user!(),
           "cartao-de-credito"
         ) do
      nil -> nil
      category -> category.id
    end
  end

  defp maybe_match_credit_card_payment(%Transaction{} = tx) do
    cc_id = get_credit_card_category_id()

    if cc_id && tx.category_id == cc_id do
      CreditCardMatcher.match_payment(tx)
    end

    :ok
  end

  @doc """
  Unlinks all transactions sharing the same reimbursement_link_key.
  """
  def unlink_reimbursement_by_key(nil), do: :ok

  def unlink_reimbursement_by_key(link_key) do
    # 1. Restore negative transactions (expenses) to 'pending'
    from(t in Transaction,
      where: t.reimbursement_link_key == ^link_key and t.amount < 0
    )
    |> Repo.update_all(
      set: [
        reimbursement_status: "pending",
        reimbursement_link_key: nil,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    # 2. Clear positive transactions (credits) completely
    from(t in Transaction,
      where: t.reimbursement_link_key == ^link_key and t.amount > 0
    )
    |> Repo.update_all(
      set: [
        reimbursement_status: nil,
        reimbursement_link_key: nil,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    :ok
  end

  @doc """
  Rejects a reimbursement pair so it won't be suggested again.
  """
  def reject_reimbursement_pair(tx_id_a, tx_id_b) do
    %RejectedReimbursementPair{}
    |> RejectedReimbursementPair.changeset(%{
      transaction_a_id: tx_id_a,
      transaction_b_id: tx_id_b
    })
    |> Repo.insert()
  end

  @doc """
  Given a list of transfer_keys, returns a map %{transfer_key => [tx, tx]}
  with both sides of each pair preloaded with account.
  """
  def get_transfer_pairs([]), do: %{}

  def get_transfer_pairs(transfer_keys) do
    from(t in Transaction,
      where: t.transfer_key in ^transfer_keys,
      preload: [:account]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.transfer_key)
  end

  @doc """
  Returns `%{reimbursement_link_key => [transaction]}` for the given link keys,
  so a row can name (and open) the transaction on the other side of its
  reimbursement — the expense from the deposit credit and vice-versa.
  """
  def get_reimbursement_pairs([]), do: %{}

  def get_reimbursement_pairs(link_keys) do
    from(t in Transaction,
      where: t.reimbursement_link_key in ^link_keys,
      order_by: [asc: t.amount, asc: t.id],
      preload: [:account]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.reimbursement_link_key)
  end

  @doc """
  Returns the count of transactions without a category.
  """
  def count_pending_transactions do
    Repo.aggregate(from(t in Transaction, where: is_nil(t.category_id)), :count)
  end

  @doc """
  Returns the "statement health" metrics shown on the transactions screen when
  no filter is active: how many rows still lack a category, how much money is
  still expected back from reimbursable expenses, and how many transactions
  categorized as transfers have no matching counterpart yet.

  All three are single aggregate queries so the bar stays cheap to render on
  every stream refresh.
  """
  def statement_health do
    %{
      uncategorized_count: count_pending_transactions(),
      reimbursements_receivable_count: count_reimbursements_receivable(),
      reimbursements_receivable_total: total_reimbursements_receivable(),
      unmatched_transfers_count: count_unmatched_transfers()
    }
  end

  defp reimbursements_receivable_query do
    from(t in Transaction,
      where: is_nil(t.reimbursement_link_key),
      where: t.amount < 0,
      where: t.reimbursement_status in ["pending", "requested"]
    )
  end

  defp count_reimbursements_receivable do
    Repo.aggregate(reimbursements_receivable_query(), :count)
  end

  defp total_reimbursements_receivable do
    total =
      reimbursements_receivable_query()
      |> select([t], sum(fragment("ABS(?)", t.amount)))
      |> Repo.one()

    total || Decimal.new("0")
  end

  defp count_unmatched_transfers do
    from(t in Transaction,
      join: c in assoc(t, :category),
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
  def list_transfer_suggestions do
    transfer_cat = Categories.get_category_by_slug(CashLens.Ownership.current_user!(), "transfer")
    transfer_cat_id = transfer_cat && transfer_cat.id

    transfer_suggestion_candidates_query(transfer_cat_id)
    |> Repo.all()
    |> pick_disjoint_pairs()
    |> Enum.map(&order_transfer_pair/1)
  end

  defp transfer_suggestion_candidates_query(transfer_cat_id) do
    window = @transfer_pairing_window_days

    from(a in Transaction,
      join: acct_a in assoc(a, :account),
      as: :acct_a,
      join: b in Transaction,
      on:
        fragment("ABS(? - ?) <= ?", a.date, b.date, ^window) and
          a.amount == fragment("? * -1", b.amount) and
          a.account_id != b.account_id and
          a.id < b.id,
      join: acct_b in assoc(b, :account),
      as: :acct_b,
      where: is_nil(a.transfer_key) and is_nil(b.transfer_key),
      where:
        (is_nil(a.category_id) or a.category_id == ^transfer_cat_id) and
          (is_nil(b.category_id) or b.category_id == ^transfer_cat_id),
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Scopes.cash_account_binding(:acct_a)
    |> Scopes.cash_account_binding(:acct_b)
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
  defp order_transfer_pair({a, b}) do
    a = Repo.preload(a, [:account, :category])
    b = Repo.preload(b, [:account, :category])
    if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
  end

  @doc """
  Returns unmatched transfers (transfer category, no transfer_key) that have
  no auto-suggestion pair.

  Callers that already hold the output of `list_transfer_suggestions/0` can pass
  it in to avoid recomputing the pairing query.
  """
  def list_unmatched_transfers_without_suggestion(suggestions \\ nil) do
    transfer_cat = Categories.get_category_by_slug(CashLens.Ownership.current_user!(), "transfer")

    if is_nil(transfer_cat) do
      []
    else
      suggested_ids =
        (suggestions || list_transfer_suggestions())
        |> Enum.flat_map(fn {out, inc} -> [out.id, inc.id] end)

      from(t in Transaction,
        where: is_nil(t.transfer_key),
        where: t.category_id == ^transfer_cat.id,
        where: t.id not in ^suggested_ids,
        order_by: [desc: t.date],
        preload: [:account, :category]
      )
      |> Scopes.cash_accounts_only()
      |> Repo.all()
    end
  end

  @doc """
  Returns manual-link candidates for `transaction`: opposite-sign, unmatched
  transactions on other accounts within
  #{@transfer_link_window_days} days, each annotated with the absolute amount
  difference and the number of days between the two dates.

  Sorted by amount difference, then by day difference, so the closest match
  comes first.
  """
  def list_transfer_link_candidates(%Transaction{} = transaction) do
    transfer_cat = Categories.get_category_by_slug(CashLens.Ownership.current_user!(), "transfer")
    transfer_cat_id = transfer_cat && transfer_cat.id
    opposite_sign = if Decimal.negative?(transaction.amount), do: :positive, else: :negative

    from(t in Transaction,
      where: t.id != ^transaction.id,
      where: t.account_id != ^transaction.account_id,
      where: is_nil(t.transfer_key),
      where: is_nil(t.category_id) or t.category_id == ^transfer_cat_id,
      where: fragment("ABS(? - ?) <= ?", t.date, ^transaction.date, ^@transfer_link_window_days),
      preload: [:account]
    )
    |> Scopes.cash_accounts_only()
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

  Returns `{:error, :same_account}` when the destination is the origin account,
  and `{:error, :already_linked}` when the transaction already belongs to a pair.
  """
  def create_mirror_transaction(transaction_id, destination_account_id) do
    origin = get_transaction!(transaction_id)

    cond do
      origin.account_id == destination_account_id ->
        {:error, :same_account}

      not is_nil(origin.transfer_key) ->
        {:error, :already_linked}

      true ->
        insert_mirror(origin, destination_account_id)
    end
  end

  defp insert_mirror(origin, destination_account_id) do
    transfer_cat = Categories.get_category_by_slug(CashLens.Ownership.current_user!(), "transfer")
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

    case %Transaction{} |> Transaction.changeset(attrs) |> Repo.insert() do
      {:ok, mirror} ->
        {:ok, _} =
          origin
          |> Transaction.changeset(%{
            transfer_key: transfer_key,
            category_id: attrs.category_id || origin.category_id
          })
          |> Repo.update()

        CashLens.Accounting.rebuild_account_balances(destination_account_id)

        {:ok, Repo.preload(mirror, [:account, :category])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns all linked transfer pairs as {tx_out, tx_in} tuples, sorted by date desc.
  """
  def list_linked_transfer_pairs do
    from(a in Transaction,
      join: b in Transaction,
      on: a.transfer_key == b.transfer_key and a.id < b.id,
      where: not is_nil(a.transfer_key),
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.map(fn {a, b} ->
      a = Repo.preload(a, [:account])
      b = Repo.preload(b, [:account])
      if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
    end)
  end

  @doc """
  Returns suggested reimbursement pairs: same absolute amount, date within 15 days,
  both unmatched, where the debit is marked as 'pending' or 'requested' for reimbursement,
  and the credit is not a transfer/initial value.
  Returns a list of {expense, credit} tuples sorted by date desc.
  """
  def list_reimbursement_suggestions do
    excluded_ids = excluded_reimbursement_category_ids()

    reimbursement_suggestions_query(excluded_ids)
    |> Repo.all()
    |> Enum.filter(fn {a, b} ->
      {expense, credit} = if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
      diff = Date.diff(credit.date, expense.date)

      diff >= 0 and diff <= 15 and
        is_nil(a.transfer_key) and is_nil(b.transfer_key) and
        a.reimbursement_status != "paid" and b.reimbursement_status != "paid"
    end)
    |> Enum.map(&order_reimbursement_pair/1)
  end

  defp reimbursement_suggestions_query(excluded_ids) do
    from(a in Transaction,
      join: b in Transaction,
      on:
        a.amount == fragment("? * -1", b.amount) and
          a.id < b.id,
      join: acc_a in assoc(a, :account),
      join: acc_b in assoc(b, :account),
      left_join: rp in RejectedReimbursementPair,
      on: rp.transaction_a_id == a.id and rp.transaction_b_id == b.id,
      where: is_nil(rp.id),
      where: is_nil(a.reimbursement_link_key) and is_nil(b.reimbursement_link_key),
      where: is_nil(a.category_id) or a.category_id not in ^excluded_ids,
      where: is_nil(b.category_id) or b.category_id not in ^excluded_ids,
      where: acc_a.accepts_import == true and acc_b.accepts_import == true,
      order_by: [desc: a.date],
      select: {a, b}
    )
  end

  defp excluded_reimbursement_category_ids do
    Enum.flat_map(@excluded_reimbursement_slugs, fn slug ->
      case Repo.one(from c in CashLens.Categories.Category, where: c.slug == ^slug, select: c.id) do
        nil ->
          []

        id ->
          CashLens.Categories.get_category_ids_with_children(
            CashLens.Ownership.current_user!(),
            id
          )
      end
    end)
    |> Enum.uniq()
  end

  defp order_reimbursement_pair({a, b}) do
    a = Repo.preload(a, [:account, :category])
    b = Repo.preload(b, [:account, :category])
    if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
  end

  @doc """
  Returns unmatched reimbursement expenses (pending or requested) that have no auto-suggestion pair.
  """
  def list_unmatched_reimbursements_without_suggestion do
    suggestions = list_reimbursement_suggestions()

    suggested_ids =
      Enum.flat_map(suggestions, fn {a, b} -> [a.id, b.id] end)
      |> MapSet.new()

    from(t in Transaction,
      where: is_nil(t.reimbursement_link_key),
      where: t.amount < 0,
      where: t.reimbursement_status in ["pending", "requested"],
      where: t.id not in ^MapSet.to_list(suggested_ids),
      order_by: [asc: t.date],
      preload: [:account, :category]
    )
    |> Repo.all()
  end

  @doc """
  Returns all linked reimbursement pairs as {expense, credit} tuples, sorted by date desc.
  """
  def list_linked_reimbursement_pairs do
    from(a in Transaction,
      join: b in Transaction,
      on: a.reimbursement_link_key == b.reimbursement_link_key and a.id < b.id,
      where: not is_nil(a.reimbursement_link_key),
      order_by: [desc: a.date],
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.map(fn {a, b} ->
      a = Repo.preload(a, [:account, :category])
      b = Repo.preload(b, [:account, :category])
      if Decimal.lt?(a.amount, Decimal.new("0")), do: {a, b}, else: {b, a}
    end)
  end

  @doc """
  Links a group of expenses and credits under a single reimbursement link key, setting all of them to the same category_id.
  """
  def link_reimbursement_group(expense_ids, credit_ids, category_id) do
    link_key = Ecto.UUID.generate()

    Repo.transaction(fn ->
      updated_expenses =
        Enum.map(expense_ids, fn id ->
          tx = get_transaction!(id)

          {:ok, updated} =
            update_transaction(tx, %{
              reimbursement_status: "paid",
              reimbursement_link_key: link_key,
              category_id: category_id
            })

          updated
        end)

      updated_credits =
        Enum.map(credit_ids, fn id ->
          tx = get_transaction!(id)

          {:ok, updated} =
            update_transaction(tx, %{
              reimbursement_status: "paid",
              reimbursement_link_key: link_key,
              category_id: category_id
            })

          updated
        end)

      {updated_expenses, updated_credits}
    end)
  end

  @doc """
  Links an expense and a credit transaction as a reimbursement.
  """
  def link_reimbursement_pair(expense_id, credit_id, category_id \\ nil) do
    expense = get_transaction!(expense_id)
    credit = get_transaction!(credit_id)
    final_category_id = category_id || expense.category_id || credit.category_id

    case link_reimbursement_group([expense_id], [credit_id], final_category_id) do
      {:ok, {[updated_expense], [updated_credit]}} ->
        {:ok, {updated_expense, updated_credit}}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc """
  Links two transactions as a transfer pair and ensures both are categorized as 'transfer'.
  """
  def link_transfer_pair(tx_id_a, tx_id_b) do
    link_key = Ecto.UUID.generate()

    transfer_cat =
      CashLens.Categories.get_category_by_slug(CashLens.Ownership.current_user!(), "transfer")

    cat_id = transfer_cat && transfer_cat.id
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      from(t in Transaction, where: t.id in [^tx_id_a, ^tx_id_b])
      |> Repo.update_all(set: [transfer_key: link_key, category_id: cat_id, updated_at: now])
    end)

    {:ok, link_key}
  end

  @doc """
  Unlinks a transfer pair by clearing the transfer_key from both transactions.
  """
  def unlink_transfer_pair(transfer_key) do
    Repo.transaction(fn ->
      from(t in Transaction, where: t.transfer_key == ^transfer_key)
      |> Repo.update_all(
        set: [
          transfer_key: nil,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
    end)
  end

  @doc """
  Suggests an installment group and next installment number for a transaction.
  """
  def suggest_installment_link(%Transaction{} = tx) do
    case CashLens.Installments.find_matching_group(tx.description) do
      nil ->
        nil

      group ->
        progress = CashLens.Installments.get_group_with_progress(group.id)

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
  through to `get_historical_summary/1`.

  The average deliberately spans whole months only. A month still running
  would drag the baseline towards whatever today happens to be, which is the
  very thing being measured.
  """
  def spend_rate(month, expenses, today \\ Date.utc_today(), opts \\ [])

  def spend_rate(%Date{} = month, expenses, %Date{} = today, opts) do
    months = Keyword.get(opts, :months, @spend_rate_months)

    previous =
      opts
      |> Keyword.take([:excluded_category_ids])
      |> Keyword.put(:limit, months + 2)
      |> get_historical_summary()
      |> Enum.filter(&earlier_month?(&1, month))
      |> Enum.take(-months)

    {total, days} =
      Enum.reduce(previous, {Decimal.new(0), 0}, fn row, {total, days} ->
        {Decimal.add(total, row.expenses),
         days + Date.days_in_month(Date.new!(row.year, row.month, 1))}
      end)

    per_day = per_day(expenses, covered_days(month, today))
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
         %Date{year: year, month: month} = first,
         %Date{year: year, month: month} = today
       ) do
    case last_movement_on_or_before(first, today) do
      nil -> 1
      %Date{} = last -> max(Date.diff(last, first) + 1, 1)
    end
  end

  defp covered_days(%Date{} = month, _today), do: Date.days_in_month(month)

  defp last_movement_on_or_before(first, today) do
    Transaction
    |> Scopes.cash_accounts_only()
    |> where([t], t.date >= ^first and t.date <= ^today)
    |> select([t], max(t.date))
    |> Repo.one()
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
