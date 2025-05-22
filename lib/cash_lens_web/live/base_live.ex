defmodule CashLensWeb.BaseLive do
  @moduledoc false
  use CashLensWeb, :live_view

  def on_mount(:default, _params, %{"current_user" => current_user} = _session, socket) do
    IO.inspect(socket)
    {:cont, assign(socket, :current_user, current_user)}
  end

  defmacro __using__(_) do
    quote do
      def handle_params(_params, uri, socket) do
        {:noreply, assign(socket, :current_path, URI.parse(uri).path)}
      end

    end
  end


end
