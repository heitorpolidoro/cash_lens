# TODO Review
defmodule CashLensWeb.TransferHTML do
  use CashLensWeb, :html
  alias CashLens.Helper
  alias CashLens.Accounts

  embed_templates "transfer_html/*"

  @doc """
  Renders a transfer form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def transfer_form(assigns)
end
