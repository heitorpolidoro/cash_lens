defmodule CashLensWeb.RecurringSyncFlash do
  @moduledoc """
  Tells whoever is on screen when a background sync has finished.

  The sync runs in an Oban job, several seconds after the import that triggered
  it, so by the time it finishes the person has usually moved on. Without this
  the registered accounts changed underneath them with nothing said; the next
  screen they opened simply disagreed with the one before.

  Attached to every LiveView in the app's `live_session`, because the message
  should reach the screen they are actually on, not only the forecast.

  A screen that also *displays* what the sync changed assigns
  `:recurring_sync_refresh`, a one-argument function this calls to rebuild it.
  Rebuilding here instead would mean knowing how each screen is assembled, and
  there is only one that cares.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, connected?: 1]

  @topic "forecast:recurring_sync"

  @doc "The PubSub topic a finished sync is announced on."
  def topic, do: @topic

  @doc "Announces a finished sync to every connected screen."
  def broadcast(%{created: _, updated: _, deactivated: _} = result) do
    Phoenix.PubSub.broadcast(CashLens.PubSub, @topic, {:recurring_synced, result})
  end

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CashLens.PubSub, @topic)

    {:cont,
     attach_hook(socket, :recurring_sync_flash, :handle_info, fn
       {:recurring_synced, result}, socket ->
         {:halt, announce(socket, result)}

       _message, socket ->
         {:cont, socket}
     end)}
  end

  # A sync that changed nothing is the common case -- it runs after every
  # import -- and saying so every time would train the flash to be ignored.
  defp announce(socket, %{created: 0, updated: 0, deactivated: 0}), do: socket

  defp announce(socket, result) do
    socket
    |> put_flash(:info, "Histórico sincronizado: #{summary(result)}.")
    |> refresh_projection()
  end

  defp summary(%{created: created, updated: updated, deactivated: deactivated}) do
    [
      {created, "incluída", "incluídas"},
      {updated, "atualizada", "atualizadas"},
      {deactivated, "desativada", "desativadas"}
    ]
    |> Enum.reject(fn {count, _one, _many} -> count == 0 end)
    |> Enum.map_join(", ", fn
      {1, one, _many} -> "1 conta #{one}"
      {count, _one, many} -> "#{count} contas #{many}"
    end)
  end

  # A screen showing what the sync changed is showing stale numbers until it
  # rebuilds, and only it knows how.
  defp refresh_projection(socket) do
    case socket.assigns[:recurring_sync_refresh] do
      refresh when is_function(refresh, 1) -> refresh.(socket)
      nil -> socket
    end
  end
end
