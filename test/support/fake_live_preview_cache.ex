defmodule CashLens.FakeLivePreviewCache do
  @moduledoc """
  A stand-in for `CashLens.Pluggy.LivePreviewCache`, swapped in via
  `Application.put_env(:cash_lens, :pluggy_live_preview_cache, __MODULE__)`.
  Shared by every test that needs to control what "live" Pluggy data a page
  sees without a real GenServer or network call.
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{entries: %{}, status: {:ok, DateTime.utc_now()}} end,
      name: __MODULE__
    )
  end

  def set_entries(entries) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :entries, entries))
  end

  def set_status(status) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :status, status))
  end

  def get_entries(account_id), do: Agent.get(__MODULE__, &Map.get(&1.entries, account_id, []))
  def get_all_entries, do: Agent.get(__MODULE__, & &1.entries) |> Map.values() |> List.flatten()
  def get_status, do: Agent.get(__MODULE__, & &1.status)

  defp ensure_started do
    case start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
