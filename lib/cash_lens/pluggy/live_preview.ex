defmodule CashLens.Pluggy.LivePreview do
  @moduledoc """
  Fetches Pluggy transactions live, normalizes them, and returns them —
  never persists anything. This is the entire replacement for the deleted
  `CashLens.Pluggy.Sync`'s persist-and-reconcile path (see
  docs/superpowers/specs/2026-08-05-pluggy-live-preview-design.md for why).

  `normalize_amount/2` and the date-parsing logic below were carried over
  verbatim from the deleted `Sync` module — both were independently verified
  against real Pluggy data earlier in the same session that removed `Sync`
  (a BANK-amount sign bug and a UTC-vs-BRT timezone bug, both fixed and
  confirmed correct against live data before this rewrite).
  """

  require Logger

  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client
  alias CashLens.Pluggy.LivePreview.Entry
  alias CashLens.Transactions

  @default_lookback_days 90

  @doc """
  Fetches every linked account's transactions from that account's own
  latest stored transaction date (or #{@default_lookback_days} days back if
  it has none) through today. Returns `{:ok, %{account_id => [Entry.t()]}}`
  with every linked account present as a key — an account whose own fetch
  failed contributes `[]`, it does not fail the whole call. Only a total
  failure (bad/missing credentials, can't authenticate at all) returns
  `{:error, reason}`.
  """
  @spec fetch_all(keyword()) :: {:ok, %{Ecto.UUID.t() => [Entry.t()]}} | {:error, term()}
  def fetch_all(req_options \\ default_req_options()) do
    with {:ok, client_id} <- fetch_env("PLUGGY_CLIENT_ID"),
         {:ok, client_secret} <- fetch_env("PLUGGY_CLIENT_SECRET"),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options) do
      entries =
        Pluggy.list_linked_account_links()
        |> Map.new(fn link ->
          {link.account_id, fetch_account_entries(link, api_key, req_options)}
        end)

      {:ok, entries}
    end
  end

  defp fetch_account_entries(link, api_key, req_options) do
    from_date = from_date(link.account_id)

    case Client.list_transactions(api_key, link.pluggy_account_id, from_date, req_options) do
      {:ok, pluggy_transactions} ->
        Enum.flat_map(pluggy_transactions, &safe_to_entry(link, &1))

      {:error, reason} ->
        Logger.warning(
          "Pluggy live preview: failed to fetch account #{link.account_id} " <>
            "(pluggy_account_id #{link.pluggy_account_id}): #{inspect(reason)}"
        )

        []
    end
  end

  # The client-side date filter is inclusive (`date >= from_date`), so using
  # the latest stored date verbatim would re-fetch — and re-render as a
  # "temporary" duplicate — every transaction already persisted on that day.
  # Start from the day after instead. With no stored transactions at all
  # there is no such boundary, so the plain lookback window applies.
  defp from_date(account_id) do
    case Transactions.latest_transaction_date(account_id) do
      nil -> Date.add(Date.utc_today(), -@default_lookback_days)
      date -> Date.add(date, 1)
    end
  end

  # A single malformed transaction must not abort the whole account's
  # fetch — degrade gracefully by skipping just that row (mirrors the
  # deleted Sync module's same per-row rescue philosophy).
  defp safe_to_entry(link, pluggy_transaction) do
    [to_entry(link, pluggy_transaction)]
  rescue
    exception ->
      Logger.warning(
        "Pluggy live preview: skipping malformed transaction for account " <>
          "#{link.account_id}: #{Exception.message(exception)}"
      )

      []
  end

  defp to_entry(link, pluggy_transaction) do
    %Entry{
      id: "pluggy-preview-" <> pluggy_transaction["id"],
      account_id: link.account_id,
      date: parse_date(pluggy_transaction["date"]),
      description: pluggy_transaction["description"],
      amount: normalize_amount(link.pluggy_account_type, pluggy_transaction),
      pluggy_category: pluggy_transaction["category"]
    }
  end

  @doc """
  Normalizes a Pluggy transaction's amount to the cash_lens convention
  (negative = expense, positive = income).

    * `"BANK"` accounts: Pluggy already returns `amount` correctly signed
      (negative for `"DEBIT"`, positive for `"CREDIT"`) — verified against
      real BB and Bradesco checking-account data. `type` is not used to
      determine sign; it is only required to be present so a malformed row
      missing it still degrades to being skipped instead of guessing.
    * `"CREDIT"` accounts: Pluggy's `amount` is already signed, but
      inverted (positive = purchase/expense) relative to cash_lens.
  """
  def normalize_amount("BANK", %{"amount" => amount, "type" => _type}),
    do: to_decimal(amount)

  def normalize_amount("CREDIT", %{"amount" => amount}),
    do: amount |> to_decimal() |> Decimal.negate()

  defp to_decimal(amount) when is_float(amount), do: Decimal.from_float(amount)
  defp to_decimal(amount) when is_integer(amount), do: Decimal.new(amount)
  defp to_decimal(%Decimal{} = amount), do: amount

  # Pluggy timestamps are UTC instants; Brazil has used a fixed UTC-3 offset
  # (no DST) since 2019, so shifting by 3 hours before taking the date gives
  # the same calendar day the bank itself reports (matching CSV imports).
  defp parse_date(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt |> DateTime.add(-3, :hour) |> DateTime.to_date()
      _ -> Date.from_iso8601!(String.slice(iso8601, 0, 10))
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, :missing_credentials}
      "" -> {:error, :missing_credentials}
      value -> {:ok, value}
    end
  end

  defp default_req_options, do: Application.get_env(:cash_lens, :pluggy_req_options, [])
end
