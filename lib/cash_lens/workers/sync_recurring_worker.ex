defmodule CashLens.Workers.SyncRecurringWorker do
  @moduledoc """
  Re-derives the registered monthly accounts from transaction history.

  Detection reads transactions, and transactions only arrive through an import,
  so an import is the moment the answer can have changed. Leaving it on a button
  meant the forecast quietly described last season's bills until someone
  remembered to press it.

  The job waits a few seconds before running, which is what lets `unique`
  collapse a directory import: thirty files enqueue thirty times, and while the
  first is still `scheduled` the rest are recognised as the same request. With
  no delay the job finished between files and each one queued its own run.

  `:executing` is deliberately NOT in the uniqueness states. A job that has
  already started cannot see rows written after it started, so letting it stand
  in for a later request would leave the last file of a batch unaccounted for
  until the next import. A run that overlaps the one before it is the cheaper
  mistake, and `sync_all/0` is idempotent anyway -- it skips manually edited
  items and writes the same day and amount for everything else.

  The two numbers answer different questions: @delay_seconds is how long to
  wait for the rest of a batch, and the uniqueness period is how far back to
  look for a request already waiting.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled]]

  alias CashLens.Forecast
  alias CashLensWeb.RecurringSyncFlash

  require Logger

  # Long enough to cover the gap between two files of the same import, short
  # enough that nobody waiting on the forecast notices it.
  @delay_seconds 5

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Row-level security: a job has no logged-in user, so it acts for the operator.
    CashLens.Ownership.pin_operator!()
    result = Forecast.sync_all()
    %{created: created, updated: updated, deactivated: deactivated} = result

    if created + updated + deactivated > 0 do
      Logger.info(
        "RECURRING SYNC: #{created} criadas, #{updated} atualizadas, #{deactivated} desativadas"
      )
    end

    # The person who triggered this has usually moved on by now, so the result
    # goes to whatever screen they are on rather than nowhere.
    RecurringSyncFlash.broadcast(result)

    :ok
  end

  @doc "How long a queued sync waits before running, in seconds."
  def delay_seconds, do: @delay_seconds

  @doc """
  Queues a sync. Never fails the caller: an import that wrote its rows has done
  its job, and a projection that refreshes on the next import is a smaller
  problem than an import reported as failed.
  """
  def enqueue do
    %{}
    |> __MODULE__.new(schedule_in: @delay_seconds)
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
