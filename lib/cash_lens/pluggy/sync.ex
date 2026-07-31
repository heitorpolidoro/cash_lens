defmodule CashLens.Pluggy.Sync do
  @moduledoc """
  Orchestrates a Pluggy sync: fetch transactions for one linked account,
  normalize Pluggy's per-account-type sign convention, create them via the
  same `Transactions.create_transaction/1` the rest of the app uses (so
  dedupe, transfer matching, credit-card-payment matching, and balance
  rebuild all come for free), and — for CREDIT accounts — find-or-update
  the current statement instead of ever inserting a second one for the
  same competência.
  """

  alias CashLens.Accounting
  alias CashLens.CreditCards
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client
  alias CashLens.Transactions

  @default_lookback_days 90

  @doc """
  Reads PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET, authenticates once, and syncs
  every account link that already has a cash_lens account chosen. One
  account failing does not stop the others — each result is reported
  individually.
  """
  def sync_all(req_options \\ default_req_options()) do
    with {:ok, client_id} <- fetch_env("PLUGGY_CLIENT_ID"),
         {:ok, client_secret} <- fetch_env("PLUGGY_CLIENT_SECRET"),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options) do
      Pluggy.list_linked_account_links()
      |> Enum.map(fn link -> {link, safe_sync_account_link(link, api_key, req_options)} end)
    end
  end

  defp safe_sync_account_link(link, api_key, req_options) do
    sync_account_link(link, api_key, req_options)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, :missing_credentials}
      "" -> {:error, :missing_credentials}
      value -> {:ok, value}
    end
  end

  # Real HTTP by default; config/test.exs overrides this to `[plug: {Req.Test,
  # CashLens.Pluggy.Client}]` (Task 2, Step 5) so callers that don't pass
  # req_options explicitly — sync_all/0 as called by the Transactions page
  # button — still resolve to Req.Test in the test environment.
  defp default_req_options, do: Application.get_env(:cash_lens, :pluggy_req_options, [])

  @doc """
  Syncs one linked account: fetches transactions since its last sync (or the
  last #{@default_lookback_days} days on a first sync), creates them, and —
  for CREDIT accounts — refreshes the current statement.
  """
  def sync_account_link(account_link, api_key, req_options \\ default_req_options()) do
    from_date = from_date(account_link)

    with {:ok, pluggy_transactions} <-
           Client.list_transactions(
             api_key,
             account_link.pluggy_account_id,
             from_date,
             req_options
           ) do
      results = Enum.map(pluggy_transactions, &import_transaction(account_link, &1))
      created = Enum.count(results, &(&1 == :created))
      skipped = Enum.count(results, &(&1 == :skipped))
      errors = Enum.count(results, &(&1 == :error))

      if account_link.pluggy_account_type == "CREDIT" do
        sync_statement(account_link, api_key, req_options)
      end

      {:ok, _} = Pluggy.touch_last_synced_at(account_link)

      {:ok, %{created: created, skipped: skipped, errors: errors}}
    end
  end

  defp from_date(%{last_synced_at: nil}),
    do: Date.add(Date.utc_today(), -@default_lookback_days)

  defp from_date(%{last_synced_at: %DateTime{} = last_synced_at}),
    do: DateTime.to_date(last_synced_at)

  defp import_transaction(account_link, pluggy_transaction) do
    attrs = %{
      account_id: account_link.account_id,
      date: parse_date(pluggy_transaction["date"]),
      description: pluggy_transaction["description"],
      amount: normalize_amount(account_link.pluggy_account_type, pluggy_transaction),
      pluggy_category: pluggy_transaction["category"]
    }

    case Transactions.create_transaction(attrs) do
      {:ok, :duplicate} -> :skipped
      {:ok, _transaction} -> :created
      {:error, _changeset} -> :error
    end
  end

  @doc """
  Normalizes a Pluggy transaction's amount to the cash_lens convention
  (negative = expense, positive = income).

    * `"BANK"` accounts: Pluggy's `amount` is always positive; `type`
      (`"DEBIT"` / `"CREDIT"`) says the direction.
    * `"CREDIT"` accounts: Pluggy's `amount` is already signed, but
      inverted (positive = purchase/expense) relative to cash_lens.
  """
  def normalize_amount("BANK", %{"amount" => amount, "type" => "DEBIT"}),
    do: amount |> to_decimal() |> Decimal.negate()

  def normalize_amount("BANK", %{"amount" => amount, "type" => "CREDIT"}),
    do: to_decimal(amount)

  def normalize_amount("CREDIT", %{"amount" => amount}),
    do: amount |> to_decimal() |> Decimal.negate()

  defp to_decimal(amount) when is_float(amount), do: Decimal.from_float(amount)
  defp to_decimal(amount) when is_integer(amount), do: Decimal.new(amount)
  defp to_decimal(%Decimal{} = amount), do: amount

  defp parse_date(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> Date.from_iso8601!(String.slice(iso8601, 0, 10))
    end
  end

  defp sync_statement(account_link, api_key, req_options) do
    with {:ok, accounts} <-
           Client.list_accounts(api_key, account_link.pluggy_item.item_id, req_options),
         %{
           "creditData" => %{"balanceDueDate" => due_date_str} = _credit_data,
           "balance" => balance
         }
         when is_binary(due_date_str) <-
           Enum.find(accounts, &(&1["id"] == account_link.pluggy_account_id)) do
      due_date = parse_date(due_date_str)
      competencia = Date.beginning_of_month(due_date)
      total_a_pagar = to_decimal(balance)

      statement_result =
        case CreditCards.get_statement_by_account_and_competencia(
               account_link.account_id,
               competencia
             ) do
          nil ->
            CreditCards.create_statement(%{
              account_id: account_link.account_id,
              competencia: competencia,
              due_date: due_date,
              total_a_pagar: total_a_pagar,
              source_file: "pluggy"
            })

          existing ->
            CreditCards.update_statement(existing, %{
              due_date: due_date,
              total_a_pagar: total_a_pagar
            })
        end

      case statement_result do
        {:ok, _statement} ->
          Accounting.rebuild_account_balances(account_link.account_id)

        {:error, changeset} ->
          require Logger

          Logger.warning(
            "Pluggy: failed to write credit card statement for account #{account_link.account_id}: #{inspect(changeset.errors)}"
          )
      end

      :ok
    else
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end
end
