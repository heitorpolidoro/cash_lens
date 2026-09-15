defmodule CashLensWeb.ActivePath do
  @moduledoc """
  Assigns `:current_path` to every LiveView in the app `live_session`.

  The global layout highlights the active sidebar entry and builds its
  breadcrumb from the current path. A LiveView has no access to the request
  path on its own, so this hook keeps `:current_path` in sync on mount and on
  every `handle_params` (which also covers `push_patch`/`push_navigate`).
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     attach_hook(socket, :put_current_path, :handle_params, fn _params, url, socket ->
       {:cont, assign(socket, :current_path, URI.parse(url).path)}
     end)}
  end
end
