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

  require Logger

  alias CashLens.Accounting
  alias CashLens.CreditCards
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

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

  For CREDIT accounts, the statement is resolved *before* transactions are
  imported so each transaction can be stamped with `import_batch_id` (see
  `CreditCards.statement_transactions/1`, which is how the `/statements`
  screen finds the transactions belonging to a fatura).

  `last_synced_at` only advances when the whole sync (transaction imports
  and, for CREDIT accounts, the statement write) finished without error —
  otherwise the next sync retries the same window so failed rows aren't
  skipped forever.
  """
  def sync_account_link(account_link, api_key, req_options \\ default_req_options()) do
    from_date = from_date(account_link)
    {statement, statement_ok?} = maybe_resolve_statement(account_link, api_key, req_options)
    import_batch_id = statement && statement.id

    with {:ok, pluggy_transactions} <-
           Client.list_transactions(
             api_key,
             account_link.pluggy_account_id,
             from_date,
             req_options
           ) do
      results =
        pluggy_transactions
        |> assign_pluggy_occurrence_indices(account_link)
        |> Enum.map(fn {pluggy_transaction, occurrence_index} ->
          import_transaction(account_link, pluggy_transaction, occurrence_index, import_batch_id)
        end)

      created = Enum.count(results, &(&1 == :created))
      skipped = Enum.count(results, &(&1 == :skipped))
      errors = Enum.count(results, &(&1 == :error))

      if errors == 0 and statement_ok? do
        {:ok, _} = Pluggy.touch_last_synced_at(account_link)
      end

      {:ok, %{created: created, skipped: skipped, errors: errors}}
    end
  end

  defp from_date(%{last_synced_at: nil}),
    do: Date.add(Date.utc_today(), -@default_lookback_days)

  defp from_date(%{last_synced_at: %DateTime{} = last_synced_at}),
    do: DateTime.to_date(last_synced_at)

  # Computes the 0-based occurrence index of every incoming Pluggy transaction
  # among otherwise-identical ones (same dedup_key) *within this single
  # fetch*, preserving input order. Mirrors
  # `CashLens.Parsers.Ingestor.assign_occurrence_indices/2`: without this, two
  # genuinely distinct same-day transactions (same date/amount/description)
  # would both compute occurrence_index 0 via `create_transaction/1`'s
  # manual-create default, collide on the same fingerprint, and the second
  # would be silently dropped as a "duplicate".
  defp assign_pluggy_occurrence_indices(pluggy_transactions, account_link) do
    {tagged, _seen} =
      Enum.map_reduce(pluggy_transactions, %{}, fn pluggy_transaction, seen ->
        key = pluggy_dedup_key(account_link, pluggy_transaction)
        index = Map.get(seen, key, 0)
        {{pluggy_transaction, index}, Map.put(seen, key, index + 1)}
      end)

    tagged
  end

  # A malformed transaction (missing/invalid date, amount, or type) must not
  # abort occurrence-index assignment for the whole batch — it will be caught
  # and counted as an `:error` by `import_transaction/4`'s rescue instead. A
  # unique fallback key (rather than e.g. `nil`) keeps it from colliding with
  # (and stealing an index from) other, well-formed transactions.
  defp pluggy_dedup_key(account_link, pluggy_transaction) do
    Transaction.dedup_key(%{
      account_id: account_link.account_id,
      date: parse_date(pluggy_transaction["date"]),
      description: pluggy_transaction["description"],
      amount: normalize_amount(account_link.pluggy_account_type, pluggy_transaction)
    })
  rescue
    _ -> make_ref()
  end

  defp import_transaction(account_link, pluggy_transaction, occurrence_index, import_batch_id) do
    attrs = %{
      account_id: account_link.account_id,
      date: parse_date(pluggy_transaction["date"]),
      description: pluggy_transaction["description"],
      amount: normalize_amount(account_link.pluggy_account_type, pluggy_transaction),
      pluggy_category: pluggy_transaction["category"],
      occurrence_index: occurrence_index,
      import_batch_id: import_batch_id,
      source: "pluggy"
    }

    categorizer =
      Application.get_env(:cash_lens, :auto_categorizer, CashLens.Transactions.AutoCategorizer)

    attrs = categorizer.categorize(attrs)

    if Transactions.duplicate_from_other_source?(
         attrs.account_id,
         attrs.date,
         attrs.amount,
         "pluggy"
       ) do
      :skipped
    else
      case Transactions.create_transaction(attrs) do
        {:ok, :duplicate} -> :skipped
        {:ok, _transaction} -> :created
        {:error, _changeset} -> :error
      end
    end
  rescue
    # A single malformed transaction (missing "type", nil amount/date, an
    # unrecognized account type, …) must degrade gracefully instead of
    # aborting the entire account's sync — see `normalize_amount/2`,
    # `to_decimal/1`, `parse_date/1`, none of which have fallback clauses by
    # design (guessing a sign/date for financial data would be worse than
    # skipping the row).
    _exception -> :error
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

  # Pluggy timestamps are UTC instants; Brazil has used a fixed UTC-3 offset
  # (no DST) since 2019, so shifting by 3 hours before taking the date gives
  # the same calendar day the bank itself reports (matching CSV imports).
  defp parse_date(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt |> DateTime.add(-3, :hour) |> DateTime.to_date()
      _ -> Date.from_iso8601!(String.slice(iso8601, 0, 10))
    end
  end

  # Resolves (or creates) the current statement for a CREDIT account link
  # *before* transactions are imported, so their `import_batch_id` can be set.
  # Returns `{statement_or_nil, ok?}` where `ok?` is `false` only when the
  # statement write itself failed (so the caller can skip advancing
  # `last_synced_at`) — a BANK account, or a CREDIT account whose Pluggy
  # payload has no usable credit data yet, is `{nil, true}` (nothing to sync,
  # not an error).
  defp maybe_resolve_statement(
         %{pluggy_account_type: "CREDIT"} = account_link,
         api_key,
         req_options
       ) do
    case resolve_statement(account_link, api_key, req_options) do
      {:ok, statement} -> {statement, true}
      {:error, _reason} -> {nil, false}
    end
  end

  defp maybe_resolve_statement(_account_link, _api_key, _req_options), do: {nil, true}

  defp resolve_statement(account_link, api_key, req_options) do
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

      existing =
        CreditCards.get_statement_by_account_and_competencia(account_link.account_id, competencia)

      case upsert_statement(account_link, existing, competencia, due_date, total_a_pagar) do
        {:ok, statement} ->
          Accounting.rebuild_account_balances(account_link.account_id)
          {:ok, statement}

        {:error, changeset} ->
          Logger.warning(
            "Pluggy: failed to write credit card statement for account #{account_link.account_id}: #{inspect(changeset.errors)}"
          )

          {:error, {:statement_write_failed, changeset}}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:ok, nil}
    end
  end

  defp upsert_statement(account_link, nil, competencia, due_date, total_a_pagar) do
    CreditCards.create_statement(%{
      account_id: account_link.account_id,
      competencia: competencia,
      due_date: due_date,
      total_a_pagar: total_a_pagar,
      source_file: "pluggy"
    })
  end

  # Pluggy already owns this statement (it created it on a previous sync) —
  # safe to overwrite total_a_pagar with the latest live balance.
  defp upsert_statement(
         _account_link,
         %{source_file: "pluggy"} = existing,
         _competencia,
         due_date,
         total_a_pagar
       ) do
    CreditCards.update_statement(existing, %{due_date: due_date, total_a_pagar: total_a_pagar})
  end

  # Existing statement came from a real fatura PDF/TXT/OFX import — its
  # total_a_pagar is the authoritative *closed* statement amount. Pluggy's
  # `balance` is a live running balance that can include post-closing
  # purchases, so it must never silently replace a reconciled, file-sourced
  # total. due_date is harmless to refresh.
  defp upsert_statement(_account_link, existing, _competencia, due_date, _total_a_pagar) do
    CreditCards.update_statement(existing, %{due_date: due_date})
  end
end
