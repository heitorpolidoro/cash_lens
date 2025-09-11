defmodule CashLens.Balances do
  @moduledoc """
  The Balances context.
  """

  import Ecto.Query
  alias CashLens.Repo

  alias CashLens.Balances.Balance
  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of balances.
  """
  def list_balances do
    Balance
    |> Repo.all()
    |> Repo.preload([:account])
  end

  @doc """
  Gets a single balance.
  Raises if not found.
  """
  def get_balance!(id) do
    Balance
    |> Repo.get!(id)
    |> Repo.preload([:account])
  end

  def create_or_update_balance(attrs) do
    if balance =
         Repo.one(
           from(b in Balance,
             where: b.account_id == ^attrs.account_id and b.month == ^attrs.month,
             select: b
           )
         ) do
      update_balance(balance, attrs)
    else
      create_balance()
    end
  end

  def create_balance(attrs \\ %{}) do
    %Balance{}
    |> Balance.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a changeset for editing balance.
  """
  def change_balance(%Balance{} = balance, attrs \\ %{}) do
    Balance.changeset(balance, attrs)
  end

  @doc """
  Updates a balance.
  """
  def update_balance(%Balance{} = balance, attrs) do
    balance
    |> Balance.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, balance} -> {:ok, Repo.preload(balance, [:account])}
      error -> error
    end
  end

  def delete_balance(%Balance{} = balance) do
    Repo.delete(balance)
  end

  @doc """
  Recalculates totals for a balance based on transactions for the same month and account.
  Logic:
  - total_in: sum of positive amounts
  - total_out: sum of absolute values of negative amounts
  - balance: total_in - total_out
  - final_value: starting_value + balance + interest
  """
  def recalculate_balances() do
    from(t in Transaction,
      join: a in assoc(t, :account),
      group_by: a.id,
      select: %{
        account: a,
        balance: sum(t.amount),
        month: min(t.datetime),
        total_in: fragment("SUM(CASE WHEN ? >= 0 THEN ? ELSE 0 END)", t.amount, t.amount),
        total_out: fragment("SUM(CASE WHEN ? < 0 THEN ? ELSE 0 END)", t.amount, t.amount)
      }
    )
    |> Repo.all()
    |> Enum.each(fn %{account: account, total_in: total_in, total_out: total_out, month: month} ->
      month = %{month | day: 1}
      IO.inspect(total_in)
      balance = Decimal.add(total_in, total_out)
      starting_value = 0

      create_or_update_balance(%{
        month: DateTime.to_date(month),
        # TODO
        starting_value: starting_value,
        total_in: total_in,
        total_out: total_out,
        balance: balance,
        interest: 0,
        final_value: Decimal.add(starting_value, balance),
        account_id: account.id
      })
    end)

    #    start_date = DateTime.new!(Date.new!(year, month, 1), Time.new!(0, 0, 0), "Etc/UTC")
    #
    #    end_date =
    #      Date.new!(year, month, 1)
    #      |> Date.end_of_month()
    #      |> DateTime.new!(Time.new!(23, 59, 59), "Etc/UTC")
    #
  end
end
