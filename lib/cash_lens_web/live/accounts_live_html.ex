defmodule CashLensWeb.AccountsLiveHTML do
  use Phoenix.Component
  import CashLensWeb.CoreComponents
  alias CashLens.Parsers
  alias CashLens.Accounts

  embed_templates "accounts_live_html/*"

  def format_option(options, key) do
    Enum.into(options, %{}, fn {key, value} -> {value, key} end)[key]
  end

  def format_account_type(type) do
    format_option(Accounts.available_types(), type)
  end

  def format_parser_type(parser) do
    format_option(Parsers.available_parsers(),parser)
  end
end
