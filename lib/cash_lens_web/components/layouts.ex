defmodule CashLensWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CashLensWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The sidebar navigation, grouped in the four semantic domains of the app.

  Every entry points at a route that really exists in `CashLensWeb.Router` —
  a menu entry for a route that would 404 is worse than no entry at all.

  `match_prefix` marks entries that stay highlighted on their nested routes
  (e.g. `/accounts/new` keeps "Contas & Cartões" active). An entry without it
  is only ever active on an exact path match, which is what the dashboard
  needs so it does not light up on every screen.
  """
  def nav_groups(today \\ Date.utc_today()) do
    [
      %{
        title: "Visão Geral",
        items: [
          nav_item("Painel Principal", "/", "hero-home"),
          nav_item("Extrato Geral", "/transactions", "hero-list-bullet", "/transactions"),
          nav_item("Saldos Contábeis", "/balances", "hero-banknotes", "/balances"),
          nav_item(
            "Fechamento & Comparativo",
            "/months/#{today.year}/#{today.month}",
            "hero-calendar-days",
            "/months"
          )
        ]
      },
      %{
        title: "Conciliação & Importação",
        items: [
          nav_item("Faturas de Cartão", "/statements", "hero-credit-card", "/statements"),
          nav_item("Transferências", "/transfers", "hero-arrows-right-left", "/transfers"),
          nav_item("Reembolsos", "/reimbursements", "hero-receipt-refund", "/reimbursements"),
          nav_item("Conexões Bancárias", "/pluggy", "hero-building-library", "/pluggy")
        ]
      },
      %{
        title: "Planejamento",
        items: [
          nav_item("Parcelas & Consórcios", "/installments", "hero-squares-2x2", "/installments"),
          nav_item("Previsão de Caixa", "/forecast", "hero-arrow-trending-up", "/forecast")
        ]
      },
      %{
        title: "Cadastros & Sistema",
        items: [
          nav_item("Contas & Cartões", "/accounts", "hero-building-office-2", "/accounts"),
          nav_item("Categorias", "/categories", "hero-tag", "/categories"),
          nav_item(
            "Regras de Exclusão",
            "/admin/exclusion_rules",
            "hero-funnel",
            "/admin/exclusion_rules"
          ),
          nav_item(
            "Regras de Transferência",
            "/admin/transfer_rules",
            "hero-adjustments-horizontal",
            "/admin/transfer_rules"
          ),
          nav_item("Banco de Dados", "/admin/db", "hero-circle-stack", "/admin/db")
        ]
      }
    ]
  end

  defp nav_item(label, path, icon, match_prefix \\ nil),
    do: %{label: label, path: path, icon: icon, match_prefix: match_prefix}

  @doc """
  The path the layout should consider "current".

  LiveViews get it from the `:current_path` assign set by
  `CashLensWeb.ActivePath`; plain controller renders fall back to the conn.
  """
  def current_path(assigns) do
    cond do
      is_binary(assigns[:current_path]) -> assigns[:current_path]
      match?(%Plug.Conn{}, assigns[:conn]) -> assigns.conn.request_path
      true -> nil
    end
  end

  @doc """
  Whether a nav item should be rendered as the active route.
  """
  def nav_active?(_item, nil), do: false

  def nav_active?(item, current_path) do
    item.path == current_path or
      (is_binary(item.match_prefix) and
         (item.match_prefix == current_path or
            String.starts_with?(current_path, item.match_prefix <> "/")))
  end

  @doc """
  The `{group title, screen label}` breadcrumb for the current path, or `nil`
  when the path is not one of the mapped screens.
  """
  def nav_breadcrumb(current_path, today \\ Date.utc_today()) do
    Enum.find_value(nav_groups(today), fn group ->
      case Enum.find(group.items, &nav_active?(&1, current_path)) do
        nil -> nil
        item -> {group.title, item.label}
      end
    end)
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash kind={:success} flash={@flash} />
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <button
        class="flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
