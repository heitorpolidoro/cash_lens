defmodule CashLensWeb.TransactionsTableComponentHTML do
  use Phoenix.Component

  import CashLensWeb.CoreComponents, except: [button: 1, icon: 1]

  import SaladUI.Button
  import SaladUI.Icon


  embed_templates "transactions_table_component_html/*"

  # Helper function to format datetime consistently
  def format_datetime(transaction) do
    cond do
      Map.has_key?(transaction, :date_time) ->
        Timex.format!(transaction.date_time, "{0D}/{0M}/{YYYY} {h24}:{0m}")

      Map.has_key?(transaction, :date) && Map.has_key?(transaction, :time) ->
        "#{Timex.format!(transaction.date, "{0D}/{0M}/{YYYY}")} #{transaction.time}"

      true ->
        "N/A"
    end
  end
end
