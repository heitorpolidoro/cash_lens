defmodule CashLensWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use CashLensWeb, :controller` and
  `use CashLensWeb, :live_view`.
  """
  use CashLensWeb, :html

  embed_templates "layouts/*"

  def live_navbar(assigns) do
    ~H"""
    <.live_component module={CashLensWeb.NavbarComponent} id="navbar" current_user={@current_user} />
    """
  end

  @spec live_menu_component(any()) :: Phoenix.LiveView.Rendered.t()
  def live_menu_component(assigns) do
    ~H"""
    <.live_component module={CashLensWeb.MenuComponent} id="menu" current_path={assigns[:current_path] || "/"} />
    """
  end
end
