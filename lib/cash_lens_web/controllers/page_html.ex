defmodule CashLensWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use CashLensWeb, :html

  embed_templates "page_html/*"

  @doc "A small warning badge marking a card as including unsaved, live-fetched Pluggy data."
  def live_data_badge(assigns) do
    ~H"""
    <div
      class="tooltip"
      data-tip="Atualizado com dados temporários do Pluggy, ainda não gravados"
    >
      <span class="badge badge-xs badge-warning font-black">!</span>
    </div>
    """
  end
end
