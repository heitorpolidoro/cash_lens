# TODO Review
defmodule CashLensWeb.BalanceHTML do
  use CashLensWeb, :html
  alias CashLens.Helper

  embed_templates "balance_html/*"

  @doc """
  Renders a balance form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :accounts, :list, required: true

  def balance_form(assigns)
end
