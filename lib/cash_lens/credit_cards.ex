defmodule CashLens.CreditCards do
  @moduledoc "Credit-card statement (fatura) context."
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.CreditCards.Statement
  alias CashLens.Transactions.Transaction

  def create_statement(attrs) do
    %Statement{}
    |> Statement.changeset(attrs)
    |> Repo.insert()
  end

  def get_statement!(id), do: Repo.get!(Statement, id)

  @doc """
  :open  — no payment linked.
  :divergent — payment linked but its amount differs from the statement's
    total_a_pagar (falling back to line_total when total is nil).
  :linked — payment linked and amount matches.
  """
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
end
