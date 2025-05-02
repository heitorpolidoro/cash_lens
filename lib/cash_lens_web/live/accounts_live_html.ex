defmodule CashLensWeb.AccountsLiveHTML do
  use Phoenix.Component
  import CashLensWeb.CoreComponents

  embed_templates "accounts_live_html/*"

  def format_account_type(:checking), do: "Checking"
  def format_account_type(:credit_card), do: "Credit Card"
  def format_account_type(:investment), do: "Investment"
  def format_account_type(_), do: "Unknown"

  def format_parser_type(:bb_csv), do: "BB (CSV)"
  def format_parser_type(:csv_nimble), do: "CSV (NimbleCSV)"
  def format_parser_type(_), do: "Unknown"
end
