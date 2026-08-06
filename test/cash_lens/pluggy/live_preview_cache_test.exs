defmodule CashLens.Pluggy.LivePreviewCacheTest do
  use ExUnit.Case, async: false

  alias CashLens.Pluggy.LivePreview.Entry
  alias CashLens.Pluggy.LivePreviewCache

  defmodule StubLivePreview do
    def fetch_all(_req_options \\ []) do
      case Application.get_env(:cash_lens, :live_preview_stub_result) do
        nil -> {:ok, %{}}
        {:raise, error} -> raise error
        result -> result
      end
    end
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

    :sys.get_state(pid)

    assert {:ok, %DateTime{}} = LivePreviewCache.get_status(pid)
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]
    assert LivePreviewCache.get_all_entries(pid) == [entry]
  end

  test "refresh_now/0 triggers an out-of-band refresh with the latest stub result" do
    account_id = Ecto.UUID.generate()
    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => []}})

    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_2})
    :sys.get_state(pid)

    entry = %Entry{
      id: "pluggy-preview-2",
      account_id: account_id,
      date: ~D[2026-07-02],
      description: "NEW",
      amount: Decimal.new("-5.00")
    }

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => [entry]}})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

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
    :sys.get_state(pid)

    {:ok, first_success_at} = LivePreviewCache.get_status(pid)

    Application.put_env(:cash_lens, :live_preview_stub_result, {:error, :missing_credentials})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

    assert {:error, :missing_credentials, ^first_success_at} = LivePreviewCache.get_status(pid)
    # Entries from the last successful fetch are still served.
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]

    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => []}})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

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
    :sys.get_state(pid)

    {:ok, first_success_at} = LivePreviewCache.get_status(pid)

    # Simulate an exception from fetch_all (e.g., JSON decode error, mock not found, etc.)
    Application.put_env(:cash_lens, :live_preview_stub_result, {:raise, "Stubbed error"})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

    # Verify GenServer is still alive and has an error status with exception info
    assert {:error, {:exception, "Stubbed error"}, ^first_success_at} =
             LivePreviewCache.get_status(pid)

    # Entries from the last successful fetch are still served
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]

    # Verify recovery: a successful fetch after an exception works
    Application.put_env(:cash_lens, :live_preview_stub_result, {:ok, %{account_id => []}})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

    assert {:ok, _second_success_at} = LivePreviewCache.get_status(pid)
  end
end
