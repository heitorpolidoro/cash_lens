defmodule CashLens.Workers.SyncRecurringWorker do
  @moduledoc """
  Re-derives the registered monthly accounts from transaction history.

  Detection reads transactions, and transactions only arrive through an import,
  so an import is the moment the answer can have changed. Leaving it on a button
  meant the forecast quietly described last season's bills until someone
  remembered to press it.

  `unique` collapses a directory import -- thirty files, thirty results -- into
  one run, and `sync_all/0` is idempotent anyway: it skips manually edited items
  and writes the same day and amount for everything else.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  alias CashLens.Forecast

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{created: created, updated: updated} = Forecast.sync_all()

    if created + updated > 0 do
      Logger.info("RECURRING SYNC: #{created} criadas, #{updated} atualizadas")
    end

    :ok
  end

  @doc """
  Queues a sync. Never fails the caller: an import that wrote its rows has done
  its job, and a projection that refreshes on the next import is a smaller
  problem than an import reported as failed.
  """
  def enqueue do
    %{}
    |> __MODULE__.new()
    |> oban().insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("RECURRING SYNC: could not enqueue: #{inspect(reason)}")
        :ok
    end
  end

  defp oban, do: Application.get_env(:cash_lens, :oban_module, Oban)
end
