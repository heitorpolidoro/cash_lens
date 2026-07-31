defmodule CashLens.Pluggy.Client do
  @moduledoc """
  Thin HTTP wrapper around the three Pluggy API endpoints this app needs:
  authenticate, list a connection's accounts, list an account's
  transactions (following cursor pagination transparently).

  Every function takes a `req_options` keyword list (default `[]`) merged
  into `Req.new/1`, so tests can pass `[plug: {Req.Test, __MODULE__}]` to
  stub responses without touching the network.
  """

  @base_url "https://api.pluggy.ai"

  @doc "Exchanges clientId/clientSecret for a short-lived apiKey."
  def auth(client_id, client_secret, req_options \\ []) do
    [base_url: @base_url]
    |> Keyword.merge(req_options)
    |> Req.new()
    |> Req.post(url: "/auth", json: %{"clientId" => client_id, "clientSecret" => client_secret})
    |> handle_response(fn %{"apiKey" => api_key} -> api_key end)
  end

  @doc "Lists every account inside a Pluggy item."
  def list_accounts(api_key, item_id, req_options \\ []) do
    [base_url: @base_url]
    |> Keyword.merge(req_options)
    |> Req.new()
    |> Req.get(url: "/accounts", headers: [{"X-API-KEY", api_key}], params: [itemId: item_id])
    |> handle_response(fn %{"results" => results} -> results end)
  end

  @doc """
  Lists every transaction for an account on or after `from_date`, following
  the API's cursor pagination (`next` in the response) until exhausted, and
  returning the full flattened list.

  Fetches every page of the account's history (there is no working
  server-side date filter on the real Pluggy API — a `from` param is
  rejected) and filters to `from_date` locally. This means every call
  downloads the full transaction history, not just the delta since the
  last sync. Deliberately not optimized with an early pagination stop,
  since that would require assuming Pluggy returns pages newest-first, an
  ordering never confirmed against the real API — a wrong assumption there
  would risk silently dropping transactions, which is worse than the
  current, safe, full-fetch-then-filter approach. Acceptable for now: this
  is a manually-triggered, low-frequency import for a single-user app, not
  an automated high-volume sync.
  """
  def list_transactions(api_key, account_id, %Date{} = from_date, req_options \\ []) do
    req = Keyword.merge([base_url: @base_url], req_options) |> Req.new()
    fetch_transactions_page(req, api_key, account_id, from_date, nil, [])
  end

  defp fetch_transactions_page(req, api_key, account_id, from_date, after_cursor, acc) do
    base_params = [accountId: account_id]
    params = if after_cursor, do: base_params ++ [after: after_cursor], else: base_params

    req
    |> Req.get(url: "/v2/transactions", headers: [{"X-API-KEY", api_key}], params: params)
    |> case do
      {:ok, %{status: 200, body: %{"results" => results} = body}} ->
        # Filter results to only include transactions on or after from_date
        filtered_results =
          Enum.filter(results, fn tx ->
            case Date.from_iso8601(String.slice(tx["date"] || "", 0..9)) do
              {:ok, tx_date} -> Date.compare(tx_date, from_date) != :lt
              {:error, _} -> false
            end
          end)

        acc = acc ++ filtered_results

        case next_cursor(body["next"]) do
          nil -> {:ok, acc}
          cursor -> fetch_transactions_page(req, api_key, account_id, from_date, cursor, acc)
        end

      other ->
        handle_response(other, & &1)
    end
  end

  # `next` may be a bare cursor string, or a full URL/query string carrying
  # an `after` param — handle both without assuming which one the API sends.
  defp next_cursor(nil), do: nil

  defp next_cursor(next) when is_binary(next) do
    if String.contains?(next, "after=") do
      next
      |> URI.parse()
      |> Map.get(:query)
      |> then(&(&1 || next))
      |> URI.decode_query()
      |> Map.get("after")
    else
      next
    end
  end

  defp handle_response({:ok, %{status: 200, body: body}}, extract), do: {:ok, extract.(body)}

  defp handle_response({:ok, %{status: status, body: body}}, _extract),
    do: {:error, {status, body}}

  defp handle_response({:error, reason}, _extract), do: {:error, reason}
end
