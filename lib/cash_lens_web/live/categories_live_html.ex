defmodule CashLensWeb.CategoriesLiveHTML do
  use Phoenix.Component
  import CashLensWeb.CoreComponents
  import CashLensWeb.WebUtils

  alias CashLens.Categories.Category

  embed_templates "categories_live_html/*"

  def format_category_type(type) do
    format_option(Category.available_types(), type)
  end
end
