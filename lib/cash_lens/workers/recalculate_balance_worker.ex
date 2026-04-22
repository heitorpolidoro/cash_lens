defmodule CashLens.Workers.RecalculateBalanceWorker do
  use Oban.Worker,
    queue: :accounting,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  alias CashLens.Accounting
  alias CashLens.Repo
  alias CashLens.Accounting.Balance
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "year" => year, "month" => month}}) do
    # 1. Calculate the current month
    case Accounting.calculate_monthly_balance(account_id, year, month) do
      {:ok, _balance} ->
        # 2. Trigger the next month recalculation if it exists
        {next_year, next_month} = get_next_period(year, month)

        if Repo.get_by(Balance, account_id: account_id, year: next_year, month: next_month) do
          %{account_id: account_id, year: next_year, month: next_month}
          |> __MODULE__.new()
          |> Oban.insert()
          |> case do
            {:ok, _job} ->
              :ok

            {:error, reason} ->
              Logger.error("Failed to enqueue next balance recalculation: #{inspect(reason)}")
              {:error, reason}
          end
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("Balance recalculation failed for #{month}/#{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_next_period(year, 12), do: {year + 1, 1}
  defp get_next_period(year, month), do: {year, month + 1}
end
