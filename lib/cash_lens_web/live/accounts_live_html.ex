defmodule CashLensWeb.AccountsLiveHTML do
  use Phoenix.Component
  import CashLensWeb.CoreComponents
  import CashLensWeb.WebUtils

  alias CashLens.Parsers
  alias CashLens.Accounts.Account

  embed_templates "accounts_live_html/*"

  def format_account_type(type) do
    format_option(Account.available_types(), type)
  end

end
