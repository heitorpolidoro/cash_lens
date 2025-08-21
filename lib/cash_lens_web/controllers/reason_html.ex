defmodule CashLensWeb.ReasonHTML do
  use CashLensWeb, :html

  embed_templates "reason_html/*"

  @doc """
  Renders a reason form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :categories, :list, required: true
  attr :parent_reasons, :list, required: true

  def reason_form(assigns)
end
