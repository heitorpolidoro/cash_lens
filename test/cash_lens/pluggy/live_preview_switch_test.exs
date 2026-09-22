defmodule CashLens.Pluggy.LivePreviewSwitchTest do
  use ExUnit.Case, async: true

  # The switch is "do not start the cache", and that only works because every
  # reader already tolerates the cache being absent. These assert the two
  # properties that make it safe, so a future change to either is caught here
  # rather than by a crashed LiveView.

  test "a cast to an absent cache is a no-op, not an exit" do
    # LivePreviewCache.refresh_now/1 is a cast and is called without a
    # safe_cache/2 wrapper from two LiveViews. If it ever became a call, the
    # switch would crash those screens instead of quietly disabling the preview.
    assert :ok = GenServer.cast(CashLens.Pluggy.LivePreviewCache, :refresh)
  end

  test "refresh_now/1 against an absent cache does not raise or exit" do
    assert :ok = CashLens.Pluggy.LivePreviewCache.refresh_now()
  end

  test "reading an absent cache exits, which is what safe_cache/2 catches" do
    assert catch_exit(CashLens.Pluggy.LivePreviewCache.get_all_entries()) != nil
  end
end
