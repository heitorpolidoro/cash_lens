defmodule CashLensWeb.TransactionHTML do
  use CashLensWeb, :html

  embed_templates "transaction_html/*"

  @doc """
  Renders a transaction form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :accounts, :list, required: true
  attr :categories, :list, required: true

  def transaction_form(assigns)
end
