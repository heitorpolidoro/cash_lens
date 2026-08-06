defmodule CashLens.Pluggy.LivePreviewCache do
  @moduledoc """
  In-memory cache of the latest `CashLens.Pluggy.LivePreview.fetch_all/1`
  result. Refreshes every #{div(:timer.minutes(30), 60_000)} minutes on a
  timer, and on demand via `refresh_now/1`. Never touches the database —
  this is purely process state, lost on restart (which is fine: the next
  scheduled or manual refresh repopulates it).
  """

  use GenServer
  require Logger

  @refresh_interval :timer.minutes(30)

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Entries for one account, `[]` if none cached yet or that account has no live data."
  def get_entries(server \\ __MODULE__, account_id) do
    GenServer.call(server, {:get_entries, account_id})
  end

  @doc "Every cached entry across every account, flattened."
  def get_all_entries(server \\ __MODULE__) do
    GenServer.call(server, :get_all_entries)
  end

  @doc """
  `{:ok, last_refreshed_at}` after a successful fetch, or
  `{:error, reason, last_success_at}` (where `last_success_at` is `nil` if
  there has never been a successful fetch) after a total failure.
  """
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  @doc "Triggers an immediate out-of-band refresh, not waiting for the timer."
  def refresh_now(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    send(self(), :refresh)
    {:ok, %{entries: %{}, status: {:error, :not_yet_fetched, nil}}}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call({:get_entries, account_id}, _from, state) do
    {:reply, Map.get(state.entries, account_id, []), state}
  end

  @impl true
  def handle_call(:get_all_entries, _from, state) do
    {:reply, state.entries |> Map.values() |> List.flatten(), state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  defp do_refresh(state) do
    live_preview =
      Application.get_env(:cash_lens, :pluggy_live_preview, CashLens.Pluggy.LivePreview)

    case live_preview.fetch_all() do
      {:ok, entries} ->
        %{entries: entries, status: {:ok, DateTime.utc_now()}}

      {:error, reason} ->
        Logger.warning("Pluggy live preview cache: refresh failed: #{inspect(reason)}")
        %{state | status: {:error, reason, last_success_at(state.status)}}
    end
  rescue
    exception ->
      Logger.warning("Pluggy live preview cache: refresh raised: #{Exception.message(exception)}")

      %{
        state
        | status:
            {:error, {:exception, Exception.message(exception)}, last_success_at(state.status)}
      }
  end

  defp last_success_at({:ok, at}), do: at
  defp last_success_at({:error, _reason, at}), do: at

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
