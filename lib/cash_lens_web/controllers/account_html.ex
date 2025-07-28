defmodule CashLensWeb.AccountHTML do
  use CashLensWeb, :html
  alias CashLens.Accounts.Account
  alias CashLens.Helper

  embed_templates "account_html/*"

  @doc """
  Renders a account form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def account_form(assigns)
end
