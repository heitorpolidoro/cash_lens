defmodule CashLens.Pluggy.LivePreviewCacheTest do
  use ExUnit.Case, async: false

  alias CashLens.Pluggy.LivePreview.Entry
  alias CashLens.Pluggy.LivePreviewCache

  defmodule StubLivePreview do
    def fetch_all(_req_options \\ []) do
      case Application.get_env(:cash_lens, :live_preview_stub_result) do
        nil -> {:ok, %{}}
        {:raise, error} -> raise error
        {:sleep, ms, result} -> Process.sleep(ms) && result
        result -> result
      end
    end
  end

  # The fetch now runs in a Task spawned by the GenServer, so `:sys.get_state/1`
  # (which only proves the GenServer's own mailbox drained) is no longer a valid
  # synchronization point. Poll the observable state instead.
  defp wait_until(fun, timeout \\ 1_000)

  defp wait_until(fun, timeout) when timeout <= 0 do
    assert fun.(), "condition never became true within the timeout"
  end

  defp wait_until(fun, timeout) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, timeout - 10)
    end
  end

  defp wait_for_status(pid, matcher, timeout \\ 1_000) do
    wait_until(fn -> matcher.(LivePreviewCache.get_status(pid)) end, timeout)
  end

  defp wait_for_success(pid) do
    wait_for_status(pid, &match?({:ok, _}, &1))
    {:ok, at} = LivePreviewCache.get_status(pid)
    at
  end

  setup do
    Application.put_env(:cash_lens, :pluggy_live_preview, StubLivePreview)
    Application.put_env(:cash_lens, :live_preview_stub_result, nil)

    on_exit(fn ->
      Application.delete_env(:cash_lens, :pluggy_live_preview)
      Application.delete_env(:cash_lens, :live_preview_stub_result)
    end)

    :ok
  end

  test "starts with an :ok status and an immediate fetch" do
    account_id = Ecto.UUID.generate()

    entry = %Entry{
      id: "pluggy-preview-1",
      account_id: account_id,
      date: ~D[2026-07-01],
      description: "TEST",
      amount: Decimal.new("-10.00")
    }

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => [entry]}})

    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_1})

    wait_for_success(pid)

    assert {:ok, %DateTime{}} = LivePreviewCache.get_status(pid)
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]
    assert LivePreviewCache.get_all_entries(pid) == [entry]
  end

  test "refresh_now/0 triggers an out-of-band refresh with the latest stub result" do
    account_id = Ecto.UUID.generate()
    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => []}})

    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_2})
    wait_for_success(pid)

    entry = %Entry{
      id: "pluggy-preview-2",
      account_id: account_id,
      date: ~D[2026-07-02],
      description: "NEW",
      amount: Decimal.new("-5.00")
    }

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => [entry]}})
    LivePreviewCache.refresh_now(pid)
    wait_until(fn -> LivePreviewCache.get_entries(pid, account_id) == [entry] end)

    assert LivePreviewCache.get_entries(pid, account_id) == [entry]
  end

  test "a total failure sets an :error status while keeping the previous entries and last success time" do
    account_id = Ecto.UUID.generate()

    entry = %Entry{
      id: "pluggy-preview-3",
      account_id: account_id,
      date: ~D[2026-07-01],
      description: "TEST",
      amount: Decimal.new("-10.00")
    }

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => [entry]}})
    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_3})
    first_success_at = wait_for_success(pid)

    Application.put_env(:cash_lens, :live_preview_stub_result, {:error, :missing_credentials})
    LivePreviewCache.refresh_now(pid)
    wait_for_status(pid, &match?({:error, :missing_credentials, _}, &1))

    assert {:error, :missing_credentials, ^first_success_at} = LivePreviewCache.get_status(pid)
    # Entries from the last successful fetch are still served.
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => []}})
    LivePreviewCache.refresh_now(pid)
    wait_for_status(pid, &match?({:ok, _}, &1))

    assert {:ok, second_success_at} = LivePreviewCache.get_status(pid)
    assert DateTime.compare(second_success_at, first_success_at) != :lt
  end

  test "an exception raised by fetch_all sets an :error status instead of crashing the GenServer" do
    account_id = Ecto.UUID.generate()

    entry = %Entry{
      id: "pluggy-preview-4",
      account_id: account_id,
      date: ~D[2026-07-01],
      description: "TEST",
      amount: Decimal.new("-10.00")
    }

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => [entry]}})
    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_4})
    first_success_at = wait_for_success(pid)

    # Simulate an exception from fetch_all (e.g., JSON decode error, mock not found, etc.)
    Application.put_env(:cash_lens, :live_preview_stub_result, {:raise, "Stubbed error"})
    LivePreviewCache.refresh_now(pid)
    wait_for_status(pid, &match?({:error, {:exception, _}, _}, &1))

    # Verify GenServer is still alive and has an error status with exception info
    assert {:error, {:exception, "Stubbed error"}, ^first_success_at} =
             LivePreviewCache.get_status(pid)

    # Entries from the last successful fetch are still served
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]

    # Verify recovery: a successful fetch after an exception works
    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => []}})
    LivePreviewCache.refresh_now(pid)
    wait_for_status(pid, &match?({:ok, _}, &1))

    assert {:ok, _second_success_at} = LivePreviewCache.get_status(pid)
  end

  test "reads stay instant while a slow fetch is in flight" do
    # A real fetch is many paginated HTTP calls. If it ran inside the
    # GenServer, this read would queue behind it and eventually hit the
    # 5s call timeout — the bug this async restructuring exists to fix.
    Application.put_env(
      :cash_lens,
      :live_preview_stub_result,
      {:sleep, 700, {:ok, %{}}}
    )

    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_5})

    {micros, status} = :timer.tc(fn -> LivePreviewCache.get_status(pid) end)

    # Still the seeded, never-fetched status: the fetch has not landed yet...
    assert {:error, :not_yet_fetched, nil} = status
    # ...yet the read returned immediately rather than waiting on it.
    assert micros < 200_000

    assert {micros_entries, []} =
             :timer.tc(fn -> LivePreviewCache.get_all_entries(pid) end)

    assert micros_entries < 200_000

    # And the result does eventually land.
    wait_for_status(pid, &match?({:ok, _}, &1), 2_000)
  end
end
