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
  mistake, and `sync_all/1` is idempotent anyway -- it skips manually edited
  items and writes the same day and amount for everything else.

  The two numbers answer different questions: @delay_seconds is how long to
  wait for the rest of a batch, and the uniqueness period is how far back to
  look for a request already waiting.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 300,
      states: [:available, :scheduled],
      fields: [:worker, :args],
      keys: [:user_id]
    ]

  alias CashLens.Forecast
  alias CashLens.Repo
  alias CashLens.Users.User
  alias CashLensWeb.RecurringSyncFlash

  require Logger

  # Long enough to cover the gap between two files of the same import, short
  # enough that nobody waiting on the forecast notices it.
  @delay_seconds 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_binary(user_id) do
    # Row-level security: pin the owner before anything, the user lookup included.
    Repo.with_user(user_id, fn ->
      case load_user(user_id) do
        nil -> discard("user #{user_id} no longer exists")
        user -> sync(user)
      end
    end)
  end

  def perform(%Oban.Job{}), do: discard("missing user_id")

  defp sync(user) do
    result = Forecast.sync_all(user)
    %{created: created, updated: updated, deactivated: deactivated} = result

    if created + updated + deactivated > 0 do
      Logger.info(
        "RECURRING SYNC: #{created} criadas, #{updated} atualizadas, #{deactivated} desativadas"
      )
    end

    # The person who triggered this has usually moved on by now, so the result
    # goes to whatever screen they are on rather than nowhere -- theirs only.
    RecurringSyncFlash.broadcast(user.id, result)

    :ok
  end

  defp load_user(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> Repo.get(User, id)
      :error -> nil
    end
  end

  defp discard(reason) do
    Logger.warning("Discarding recurring sync job: #{reason}")
    {:discard, reason}
  end

  @doc "How long a queued sync waits before running, in seconds."
  def delay_seconds, do: @delay_seconds

  @doc """
  Queues a sync for `user_id`. Never fails the caller: an import that wrote its
  rows has done its job, and a projection that refreshes on the next import is a
  smaller problem than an import reported as failed.
  """
  def enqueue(user_id) when is_binary(user_id) do
    %{user_id: user_id}
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
