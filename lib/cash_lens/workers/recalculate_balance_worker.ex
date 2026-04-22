defmodule CashLens.Workers.RecalculateBalanceWorker do
  use Oban.Worker, queue: :accounting, max_attempts: 3

  alias CashLens.Accounting
  alias CashLens.Repo
  alias CashLens.Accounting.Balance

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "year" => year, "month" => month}}) do
    # 1. Calculate the current month
    {:ok, _balance} = Accounting.calculate_monthly_balance(account_id, year, month)

    # 2. Trigger the next month recalculation if it exists
    {next_year, next_month} = get_next_period(year, month)

    if Repo.get_by(Balance, account_id: account_id, year: next_year, month: next_month) do
      %{account_id: account_id, year: next_year, month: next_month}
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end

  defp get_next_period(year, 12), do: {year + 1, 1}
  defp get_next_period(year, month), do: {year, month + 1}
end
