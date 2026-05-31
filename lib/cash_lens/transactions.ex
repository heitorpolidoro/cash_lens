defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Categories.Category
  alias CashLens.Repo
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.BulkIgnorePattern
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.TransferRule
  alias CashLens.Transactions.TransferRuleApplier

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

  def delete_bulk_ignore_pattern(%BulkIgnorePattern{} = pattern) do
    Repo.delete(pattern)
  end

  def change_bulk_ignore_pattern(%BulkIgnorePattern{} = pattern, attrs \\ %{}) do
    BulkIgnorePattern.changeset(pattern, attrs)
  end

  def get_bulk_ignore_pattern!(id), do: Repo.get!(BulkIgnorePattern, id)

  @doc """
  Returns the list of transactions based on filters and pagination.
  """
  @doc """
  Returns income and expenses totals for the given filters.
  Returns %{income: Decimal, expenses: Decimal}.
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
      |> select([t], %{amount: t.amount})

    result =
      from(row in subquery(base),
        select: %{
          income: sum(fragment("CASE WHEN ? > 0 THEN ? ELSE 0 END", row.amount, row.amount)),
          expenses:
            sum(fragment("CASE WHEN ? < 0 THEN ABS(?) ELSE 0 END", row.amount, row.amount))
        }
      )
      |> Repo.one()

    %{
      income: (result && result.income) || Decimal.new("0"),
      expenses: (result && result.expenses) || Decimal.new("0")
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

  def list_transactions(filters \\ %{}, page \\ 1, page_size \\ 50) do
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
  end

  @excluded_reimbursement_slugs ["transfer", "initial_value", "salário", "salario"]

  def list_reimbursement_credit_candidates(search \\ "") do
    excluded_ids =
      Enum.flat_map(@excluded_reimbursement_slugs, fn slug ->
        case Repo.one(
               from c in CashLens.Categories.Category, where: c.slug == ^slug, select: c.id
             ) do
          nil -> []
          id -> CashLens.Categories.get_category_ids_with_children(id)
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
    |> order_by_date(sort_order)
    |> Repo.all()
  end

  defp filter_unmatched_transfers(query, "true") do
    where(query, [t], t.transfer_key |> is_nil())
    |> join(:inner, [t], c in assoc(t, :category))
    |> where([..., c], c.slug == "transfer")
  end

  defp filter_unmatched_transfers(query, _), do: query

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
    where(query, amount: ^amount)
  end

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, ""), do: query
  defp filter_by_type(query, "debit"), do: where(query, [t], t.amount < 0)
  defp filter_by_type(query, "credit"), do: where(query, [t], t.amount > 0)

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
    ids = CashLens.Categories.get_category_ids_with_children(category_id)
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
  """
  def get_monthly_summary(date \\ nil, filters \\ %{}) do
    target_date = date || get_latest_transaction_date() || Date.utc_today()
    {first_of_month, last_of_month} = get_summary_period(target_date, filters)

    result =
      Transaction
      |> build_summary_base_query()
      |> apply_summary_date_filters(first_of_month, last_of_month, filters)
      |> filter_by_account(filters["account_id"])
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
  Excludes transfers, initial values, and reimbursed transactions.
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
        where: c.slug not in ["initial_value", "transfer"],
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

  defp build_summary_base_query(query) do
    from t in query,
      left_join: c in assoc(t, :category),
      where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer"],
      where: is_nil(t.reimbursement_link_key)
  end

  defp apply_summary_date_filters(query, _first, _last, %{"category_id" => "nil"}), do: query

  defp apply_summary_date_filters(query, _first, _last, %{"unmatched_transfers" => "true"}),
    do: query

  defp apply_summary_date_filters(query, first, last, _filters) do
    where(query, [t], t.date >= ^first and t.date <= ^last)
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
  """
  def get_historical_summary(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      from t in Transaction,
        left_join: c in assoc(t, :category),
        where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer"],
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
    from t in Transaction,
      join: c in assoc(t, :category),
      left_join: p in assoc(c, :parent),
      where: t.amount < 0,
      where: c.slug not in ["initial_value", "transfer"],
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

  defp get_latest_transaction_date do
    Repo.one(from t in Transaction, select: max(t.date))
  end

  @doc """
  Gets a single transaction.
  """
  def get_transaction!(id),
    do: Repo.get!(Transaction, id) |> Repo.preload([:category, :account, :installment_group])

  @doc """
  Creates a transaction.
  """
  def create_transaction(attrs) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} ->
        TransferRuleApplier.maybe_apply_rule(transaction)
        TransferMatcher.match_transfer(transaction)
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
  Updates a transaction.
  """
  def update_transaction(%Transaction{} = transaction, attrs) do
    transaction
    |> Transaction.changeset(attrs)
    |> Repo.update()
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
  end

  @doc """
  Deletes a transaction.
  """
  def delete_transaction(%Transaction{} = transaction), do: Repo.delete(transaction)

  @doc """
  Deletes all transactions from the database.
  """
  def delete_all_transactions, do: Repo.delete_all(Transaction)

  @doc """
  Reapplies auto-categorization rules to all transactions without a category.
  """
  def reapply_auto_categorization do
    query = from t in Transaction, where: is_nil(t.category_id)
    pending_transactions = Repo.all(query)

    Enum.each(pending_transactions, fn tx ->
      updates = AutoCategorizer.categorize(tx)
      if updates.category_id, do: update_transaction_category(tx.id, updates.category_id)
    end)

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
  Returns the count of transactions without a category.
  """
  def count_pending_transactions do
    Repo.aggregate(from(t in Transaction, where: is_nil(t.category_id)), :count)
  end

  @doc """
  Returns suggested transfer pairs: same date, opposite amounts, different accounts,
  both unmatched and both categorized as 'transfer'.
  Returns a list of {tx_out, tx_in} tuples sorted by date desc.
  """
  def list_transfer_suggestions do
    transfer_cat = CashLens.Categories.get_category_by_slug("transfer")

    if is_nil(transfer_cat) do
      []
    else
      cat_id = transfer_cat.id

      from(a in Transaction,
        join: b in Transaction,
        on:
          a.date == b.date and
            a.amount == fragment("? * -1", b.amount) and
            a.account_id != b.account_id and
            a.id < b.id,
        where: is_nil(a.transfer_key) and is_nil(b.transfer_key),
        where: a.category_id == ^cat_id or b.category_id == ^cat_id,
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
  end

  @doc """
  Returns unmatched transfers (transfer category, no transfer_key) that have
  no auto-suggestion pair.
  """
  def list_unmatched_transfers_without_suggestion do
    transfer_cat = CashLens.Categories.get_category_by_slug("transfer")

    if is_nil(transfer_cat) do
      []
    else
      cat_id = transfer_cat.id

      # IDs that appear in suggestions
      paired_ids =
        from(a in Transaction,
          join: b in Transaction,
          on:
            a.date == b.date and
              a.amount == fragment("? * -1", b.amount) and
              a.account_id != b.account_id,
          where: is_nil(a.transfer_key) and is_nil(b.transfer_key),
          where: a.category_id == ^cat_id or b.category_id == ^cat_id,
          select: a.id
        )
        |> Repo.all()

      from(t in Transaction,
        where: is_nil(t.transfer_key),
        where: t.category_id == ^cat_id,
        where: t.id not in ^paired_ids,
        order_by: [desc: t.date],
        preload: [:account, :category]
      )
      |> Repo.all()
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
  Links two transactions as a transfer pair and ensures both are categorized as 'transfer'.
  """
  def link_transfer_pair(tx_id_a, tx_id_b) do
    link_key = Ecto.UUID.generate()
    transfer_cat = CashLens.Categories.get_category_by_slug("transfer")
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
end
