defmodule CashLensWeb.AutomaticTransferHTML do
  use CashLensWeb, :html
  alias CashLens.Accounts

  embed_templates "automatic_transfer_html/*"

  @doc """
  Renders a transfer form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :accounts, :list, required: true

  def transfer_form(assigns)
end
