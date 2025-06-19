defmodule CashLensWeb.CategoriesLive do
  use CashLensWeb, :live_view
  import CashLensWeb.BaseLive
  use CashLensWeb.BaseLive
  on_mount CashLensWeb.BaseLive

  alias CashLens.Categories
  alias CashLens.Categories.Category

  def render(assigns) do
    ~H"""
      <.crud {assigns} target={Category} formatter={
        %{
          type: :capitalize
        }
      }/>
    """
  end
end
