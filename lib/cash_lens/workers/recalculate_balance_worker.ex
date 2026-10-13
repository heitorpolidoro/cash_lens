defmodule CashLens.Workers.RecalculateBalanceWorker do
  @moduledoc """
  Worker to recalculate balances in the background.

  Every job names its owner in `"user_id"`. The worker only reads and writes that
  user's rows. A job without `"user_id"` (queued before ownership existed) or for a
  user that no longer exists is discarded: retrying cannot fix it.

  Oban's uniqueness covers all args by default, so `"user_id"` is part of the key and
  two users' jobs for the same account/month never collapse into one.
  """
  use Oban.Worker,
    queue: :accounting,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  alias CashLens.Accounting
  alias CashLens.Accounting.Balance
  alias CashLens.Ownership
  alias CashLens.Repo
  alias CashLens.Users.User

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "user_id" => user_id,
          "account_id" => account_id,
          "year" => year,
          "month" => month
        }
      })
      when is_binary(user_id) do
    # Row-level security: pin the owner before anything, the user lookup included.
    Repo.with_user(user_id, fn ->
      case load_user(user_id) do
        nil -> discard("user #{user_id} no longer exists")
        user -> recalculate(user, account_id, year, month)
      end
    end)
  end

  def perform(%Oban.Job{}), do: discard("missing user_id")

  defp load_user(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> Repo.get(User, id)
      :error -> nil
    end
  end

  defp discard(reason) do
    Logger.warning("Discarding balance recalculation job: #{reason}")
    {:discard, reason}
  end

  defp recalculate(user, account_id, year, month) do
    # 1. Calculate the current month
    case Accounting.calculate_monthly_balance(user, account_id, year, month) do
      {:ok, _balance} ->
        # 2. Trigger the next month recalculation if it exists
        maybe_enqueue_next_period(user, account_id, year, month)

      {:error, reason} ->
        Logger.error("Balance recalculation failed for #{month}/#{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_enqueue_next_period(user, account_id, year, month) do
    {next_year, next_month} = get_next_period(year, month)

    next_exists? =
      Balance
      |> Ownership.scope(user)
      |> Repo.get_by(account_id: account_id, year: next_year, month: next_month)

    if next_exists? do
      enqueue_job(user, account_id, next_year, next_month)
    else
      :ok
    end
  end

  defp enqueue_job(user, account_id, year, month) do
    %{user_id: user.id, account_id: account_id, year: year, month: month}
    |> __MODULE__.new()
    |> oban().insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue next balance recalculation: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_next_period(year, 12), do: {year + 1, 1}
  defp get_next_period(year, month), do: {year, month + 1}

  defp oban, do: Application.get_env(:cash_lens, :oban_module, Oban)
end
