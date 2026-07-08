defmodule CashLens.CreditCards do
  @moduledoc "Credit-card statement (fatura) context."
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.CreditCards.Statement
  alias CashLens.Transactions.Transaction
  alias Ecto.Multi

  def create_statement(attrs) do
    %Statement{}
    |> Statement.changeset(attrs)
    |> Repo.insert()
  end

  def get_statement!(id), do: Repo.get!(Statement, id)

  @doc """
  Resolves a statement's competência: the parsed due-date month when the source
  carried a Vencimento, otherwise the month of the statement's latest
  transaction. The fallback keeps every statement labelled — including sources
  with no due date at all (OFX, or Bradesco's minimal near-zero PDFs) — instead
  of leaving competência blank. Returns nil only when neither is available.
  """
  def competencia_from(%Date{} = competencia, _transactions), do: competencia

  def competencia_from(nil, transactions) do
    transactions
    |> Enum.map(&Map.get(&1, :date))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> dates |> Enum.max(Date) |> Date.beginning_of_month()
    end
  end

  @doc """
  Backfills a single already-imported statement file: creates a `Statement`
  record for it, then stamps the matching *already-existing* transactions
  with `import_batch_id` by recomputing the exact fingerprint the original
  import produced (same dedup key + same per-file occurrence index), and
  finally attempts to auto-link the statement to its payment.

  Only `import_batch_id` (and `updated_at`) are touched on the matched rows
  — category, amount, description, etc. are never modified. Rows whose
  fingerprint isn't found (e.g. already deleted) are simply not matched;
  no transactions are inserted here.
  """
  def backfill_file(account, parsed_transactions, meta, source_file) do
    {:ok, statement} =
      create_statement(%{
        account_id: account.id,
        due_date: meta.due_date,
        total_a_pagar: meta.total_a_pagar,
        competencia: competencia_from(meta.competencia, parsed_transactions),
        source_file: source_file
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    parsed_transactions
    |> with_occurrence_indices(account.id)
    |> Enum.each(fn {data, index} ->
      fp = fingerprint_for(data, account.id, index)

      from(t in Transaction, where: t.fingerprint == ^fp)
      |> Repo.update_all(set: [import_batch_id: statement.id, updated_at: now])
    end)

    line_total =
      Enum.reduce(parsed_transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))

    CashLens.CreditCards.Matcher.auto_link(statement, line_total)

    {:ok, statement}
  end

  # Mirrors CashLens.Parsers.Ingestor's assign_occurrence_indices/2: the
  # 0-based ordinal of each row among otherwise-identical rows (same
  # dedup_key) within this single file, in input order. Reproducing the
  # exact same batch order as the original import is what makes the
  # recomputed fingerprints match the fingerprints already on disk.
  defp with_occurrence_indices(parsed, account_id) do
    {tagged, _seen} =
      Enum.map_reduce(parsed, %{}, fn data, seen ->
        key = data |> Map.put(:account_id, account_id) |> Transaction.dedup_key()
        index = Map.get(seen, key, 0)
        {{data, index}, Map.put(seen, key, index + 1)}
      end)

    tagged
  end

  defp fingerprint_for(data, account_id, index) do
    data
    |> Map.put(:account_id, account_id)
    |> Transaction.fingerprint(index)
  end

  @doc """
  :absorbed — absorbed by another statement (highest priority).
  :pending — no due date, no payment linked, not absorbed.
  :open  — no payment linked (but has due date).
  :divergent — payment linked but its amount differs from the statement's
    total_a_pagar (falling back to line_total when total is nil).
  :linked — payment linked and amount matches.
  """
  def statement_status(%Statement{absorbed_by_statement_id: id}, _line_total)
      when not is_nil(id),
      do: :absorbed

  def statement_status(%Statement{due_date: nil, payment_transaction_id: nil}, _line_total),
    do: :pending

  def statement_status(%Statement{payment_transaction_id: nil}, _line_total), do: :open

  def statement_status(%Statement{} = statement, line_total) do
    payment = Repo.get!(Transaction, statement.payment_transaction_id)
    target = statement.total_a_pagar || line_total

    if Decimal.equal?(payment.amount, target) or
         Decimal.equal?(payment.amount, Decimal.negate(target)) do
      :linked
    else
      :divergent
    end
  end

  def statement_transactions(statement_id) do
    from(t in Transaction,
      where: t.import_batch_id == ^statement_id,
      order_by: [asc: t.date, asc: t.inserted_at],
      preload: [:category]
    )
    |> Repo.all()
  end

  def list_statements do
    statements =
      from(s in Statement, preload: [:account], order_by: [desc: s.due_date, desc: s.competencia])
      |> Repo.all()

    totals =
      from(t in Transaction,
        where: not is_nil(t.import_batch_id),
        group_by: t.import_batch_id,
        select: {t.import_batch_id, sum(t.amount), count(t.id)}
      )
      |> Repo.all()
      |> Map.new(fn {id, sum, count} -> {id, {sum || Decimal.new(0), count}} end)

    Enum.map(statements, fn s ->
      {line_total, line_count} = Map.get(totals, s.id, {Decimal.new(0), 0})

      %{
        statement: s,
        account: s.account,
        line_total: line_total,
        line_count: line_count,
        status: statement_status(s, line_total)
      }
    end)
  end

  def get_statement_detail(id) do
    statement = from(s in Statement, where: s.id == ^id, preload: [:account]) |> Repo.one!()
    transactions = statement_transactions(id)
    line_total = Enum.reduce(transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))

    payment =
      statement.payment_transaction_id &&
        Repo.get(Transaction, statement.payment_transaction_id) |> Repo.preload(:account)

    %{
      statement: statement,
      account: statement.account,
      transactions: transactions,
      line_total: line_total,
      payment: payment,
      status: statement_status(statement, line_total)
    }
  end

  def link_payment(%Statement{} = statement, payment_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update_all(
      :children,
      from(t in Transaction, where: t.import_batch_id in ^covered_statement_ids(statement)),
      set: [parent_transaction_id: payment_id, updated_at: now]
    )
    |> Multi.update(
      :statement,
      Statement.changeset(statement, %{payment_transaction_id: payment_id})
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{statement: s}} -> {:ok, s}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  def unlink_payment(%Statement{} = statement) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update_all(
      :children,
      from(t in Transaction, where: t.import_batch_id in ^covered_statement_ids(statement)),
      set: [parent_transaction_id: nil, updated_at: now]
    )
    |> Multi.update(:statement, Statement.changeset(statement, %{payment_transaction_id: nil}))
    |> Repo.transaction()
    |> case do
      {:ok, %{statement: s}} -> {:ok, s}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  def suggest_payment(%Statement{} = statement) do
    case CashLens.Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        nil

      category ->
        target = statement.total_a_pagar
        due = statement.due_date

        from(t in Transaction,
          where: t.category_id == ^category.id,
          where: t.account_id != ^statement.account_id,
          where: is_nil(t.parent_transaction_id),
          preload: [:account]
        )
        |> Repo.all()
        |> Enum.sort_by(fn t ->
          amount_diff =
            if target, do: Decimal.abs(Decimal.sub(t.amount, target)), else: Decimal.new(0)

          date_diff = if due, do: abs(Date.diff(t.date, due)), else: 0
          {Decimal.to_float(amount_diff), date_diff}
        end)
        |> List.first()
    end
  end

  @doc """
  Wipes a credit-card account's imported data ahead of a clean re-import:
  deletes its `credit_card_statements` and all its `transactions`. Returns
  `{deleted_statements, deleted_transactions}`.
  """
  def reset_account_statements(account_id) do
    {stmts, _} =
      from(s in Statement, where: s.account_id == ^account_id) |> Repo.delete_all()

    {txns, _} =
      from(t in Transaction, where: t.account_id == ^account_id) |> Repo.delete_all()

    {stmts, txns}
  end

  @doc """
  Absorbs a boleto's eligible earlier pending statements when the accounts
  reconcile exactly: `boleto.total_a_pagar - |sum(boleto items)| == Σ
  eligible_pending.total_a_pagar`. Stamps each absorbed statement with
  `absorbed_by_statement_id = boleto.id` and returns them. Returns [] for
  non-boletos, boletos without a total, or when the sum does not match.
  """
  def absorb_pending(%Statement{due_date: nil}), do: []
  def absorb_pending(%Statement{total_a_pagar: nil}), do: []

  def absorb_pending(%Statement{} = boleto) do
    pending = eligible_pending(boleto)

    if pending == [] do
      []
    else
      line_total = boleto.id |> statement_transactions() |> sum_amounts()
      rolled = Decimal.sub(boleto.total_a_pagar, Decimal.abs(line_total))

      sum_pending =
        Enum.reduce(pending, Decimal.new(0), &Decimal.add(&2, &1.total_a_pagar || Decimal.new(0)))

      if Decimal.equal?(rolled, sum_pending) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        ids = Enum.map(pending, & &1.id)

        from(s in Statement, where: s.id in ^ids)
        |> Repo.update_all(set: [absorbed_by_statement_id: boleto.id, updated_at: now])

        pending
      else
        []
      end
    end
  end

  defp eligible_pending(%Statement{} = boleto) do
    from(s in Statement,
      where: s.account_id == ^boleto.account_id,
      where: is_nil(s.due_date),
      where: is_nil(s.absorbed_by_statement_id),
      where: not is_nil(s.competencia),
      where: s.competencia < ^boleto.competencia
    )
    |> Repo.all()
  end

  defp sum_amounts(transactions) do
    Enum.reduce(transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))
  end

  # Statement ids whose transactions a boleto's payment covers: the boleto
  # itself plus every statement absorbed into it.
  defp covered_statement_ids(%Statement{} = boleto) do
    absorbed =
      from(s in Statement, where: s.absorbed_by_statement_id == ^boleto.id, select: s.id)
      |> Repo.all()

    [boleto.id | absorbed]
  end
end
