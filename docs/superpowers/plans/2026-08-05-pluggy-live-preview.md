# Pluggy Live Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop persisting Pluggy transactions to the database. Instead, show them as a read-only, in-memory preview — refreshed every 30 minutes and on manual trigger — in the Transactions screen's first page, clearly marked as temporary.

**Architecture:** Delete the entire persist-and-reconcile Pluggy sync path (it wrote `source: "pluggy"` rows and needed increasingly complex cross-source dedup to avoid duplicating file-imported data — moot once Pluggy never writes to the DB). Add a new `CashLens.Pluggy.LivePreview` module that fetches and normalizes Pluggy transactions without persisting them, a `CashLens.Pluggy.LivePreviewCache` GenServer that holds the latest fetch in memory, and a small integration in `CashLensWeb.TransactionLive.Index` that merges the cached entries into page 1 only.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/Postgres (unchanged usage), a plain OTP GenServer (no new dependency) for the cache.

## Global Constraints

- Every existing test must keep passing after each task; only the 3 pre-existing, unrelated failures in `test/cash_lens_web/live/installment_live_test.exs` (date-sensitive fixtures, documented earlier this session) are acceptable in any full-suite run.
- `mix format` must pass (the repo's pre-commit hook runs `mix format --check-formatted`).
- No new opt-in flag on `pluggy_account_links` — `CashLens.Pluggy.list_linked_account_links/0` (already filters to links with a non-nil `account_id`) is the sole source of truth for which accounts get a live preview.
- The `transactions.source` column and its `"file"`/`"manual"` values are unchanged and untouched by this plan — only the `"pluggy"` value stops ever being written.
- Live preview merging into `TransactionLive.Index` applies to **page 1 only**, never later pages — this is a deliberate, permanent v1 boundary, not a bug to fix later in this plan.
- Full spec: `docs/superpowers/specs/2026-08-05-pluggy-live-preview-design.md`.

---

### Task 1: Revert the persisted Pluggy sync path

**Files:**
- Delete: `lib/cash_lens/pluggy/sync.ex`
- Delete: `test/cash_lens/pluggy/sync_test.exs`
- Delete: `test/cash_lens_web/live/transaction_live/pluggy_import_test.exs`
- Modify: `lib/cash_lens_web/live/transaction_live/index.ex:7` (alias), `:234-275` (handler)
- Modify: `lib/cash_lens_web/live/transaction_live/index.html.heex:99-103` (button)
- Modify: `lib/cash_lens/transactions.ex:14-15` (aliases), `:761-902` (functions)
- Modify: `lib/cash_lens/parsers/ingestor.ex:214-308` (finalize_import/prepare_entries/cross_source_duplicate?)
- Modify: `test/cash_lens/transactions_test.exs:902-1362` (test blocks)
- Modify: `test/cash_lens/parsers/ingestor_test.exs:505-572` (test blocks)
- Modify: `lib/cash_lens/pluggy.ex` (doc comment), `lib/cash_lens/transactions/transaction.ex` (doc comment)

**Interfaces:**
- Produces: `CashLens.Parsers.Ingestor.import_file/2` and `import_directory/2` return to their pre-cross-source-dedup shape — `finalize_import/3` (not `/4`), `prepare_entries/3` returns a 2-tuple `{entries, failed_reasons}` (not 3-tuple).
- Nothing later in this plan depends on anything in this task except that it compiles and the suite is green — Task 2 builds fresh, it does not reuse deleted code.

- [ ] **Step 1: Delete the Sync module and its test**

```bash
git rm lib/cash_lens/pluggy/sync.ex test/cash_lens/pluggy/sync_test.exs test/cash_lens_web/live/transaction_live/pluggy_import_test.exs
```

- [ ] **Step 2: Remove the "Importar do Pluggy" button and its handler in `TransactionLive.Index`**

In `lib/cash_lens_web/live/transaction_live/index.ex`, remove this line (around line 7):

```elixir
  alias CashLens.Pluggy.Sync
```

Then remove the entire `handle_event("import_pluggy", ...)` clause — everything from:

```elixir
  @impl true
  def handle_event("import_pluggy", _params, socket) do
    case Sync.sync_all() do
```

through its closing:

```elixir
        {:noreply, put_flash(socket, :success, message)}
    end
  end
```

(the `end` that closes the `def handle_event(...)`, immediately followed by a blank line and the next `@impl true` for `"open_quick_category"` — leave that next handler and everything after it untouched).

In `lib/cash_lens_web/live/transaction_live/index.html.heex`, remove this block:

```heex
            <li>
              <button type="button" phx-click="import_pluggy">
                <.icon name="hero-building-library" class="size-4" /> Importar do Pluggy
              </button>
            </li>
```

- [ ] **Step 3: Remove the cross-source dedup functions from `CashLens.Transactions`**

In `lib/cash_lens/transactions.ex`, remove these two alias lines:

```elixir
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Transactions.InstallmentDetector
```

Then remove everything from the `@doc """` immediately above `def duplicate_from_other_source?/4` through the end of `defp complementary_import_source/1` — this is the whole block starting at:

```elixir
  @doc """
  Returns `true` when a transaction already exists for `account_id`, on
  `date`, for `amount`, but was recorded by the *complementary real import
  source* — "file" is foreign to "pluggy" and vice versa.
```

and ending at:

```elixir
  defp complementary_import_source("file"), do: "pluggy"
  defp complementary_import_source("pluggy"), do: "file"
  defp complementary_import_source(_other), do: nil
```

Leave `defp get_latest_transaction_date/0` (just above this block) and the `@doc """` for `get_transaction!/1` (just after it) untouched — they bound the deletion.

- [ ] **Step 4: Revert `CashLens.Parsers.Ingestor` to not check cross-source duplicates**

In `lib/cash_lens/parsers/ingestor.ex`, replace `finalize_import/3` and `prepare_entries/3`:

```elixir
  defp finalize_import(transactions_data, account_id, statement_id) do
    # Never persist transactions dated in the future — they have not happened yet.
    today = Date.utc_today()
    transactions_data = Enum.reject(transactions_data, &(Date.compare(&1.date, today) == :gt))

    {entries, failed} = prepare_entries(transactions_data, account_id, statement_id)

    {inserted_count, affected_account_ids} =
      process_entries(entries, transactions_data, account_id, statement_id)

    # Rebuild balances for all affected accounts up to the current month/year
    Enum.each(affected_account_ids, fn acc_id ->
      Accounting.rebuild_account_balances(acc_id)
    end)

    # `skipped` makes silent dedupe misses observable: it is the number of prepared
    # input rows the unique index rejected as already-present (or in-batch dups),
    # i.e. entries that did not result in an insert. A future regression that lets
    # duplicates back in would surface as a non-zero `skipped` on re-import.
    skipped = length(entries) - inserted_count

    {:ok, %{imported: inserted_count, skipped: skipped, failed: failed}}
  end

  defp prepare_entries(transactions_data, account_id, statement_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {valid, failed} =
      transactions_data
      |> assign_occurrence_indices(account_id)
      |> Enum.map(fn {data, index} ->
        try do
          {:ok, prepare_transaction_entry(data, account_id, now, index, statement_id)}
        rescue
          e -> {:error, {data[:description] || "unknown", Exception.message(e)}}
        end
      end)
      |> Enum.split_with(fn
        {:ok, _} -> true
        _ -> false
      end)

    entries = Enum.map(valid, fn {:ok, entry} -> entry end)
    reasons = Enum.map(failed, fn {:error, reason} -> reason end)
    {entries, reasons}
  end
```

This removes: the `cross_source_dupes` splitting, the `Logger.warning` cross-source-skip line, and the `cross_source_skipped` 3rd tuple element. Then remove the `cross_source_duplicate?/4` private function entirely:

```elixir
  defp cross_source_duplicate?(account_id, date, amount, description) do
    CashLens.Transactions.duplicate_installment_from_other_source?(
      account_id,
      date,
      description,
      amount,
      "file"
    ) or
      CashLens.Transactions.duplicate_from_other_source?(
        account_id,
        date,
        amount,
        "file"
      )
  end
```

(and the comment block immediately above it explaining it — delete that too). Leave `prepare_transaction_entry/5`'s `Map.put(:source, "file")` line exactly as it is — the `source` column stays meaningful, this task only removes the *use* of `source: "pluggy"` for dedup, not the `source` column itself.

- [ ] **Step 5: Remove the now-orphaned test blocks**

In `test/cash_lens/transactions_test.exs`, remove everything from `describe "duplicate_from_other_source?/4" do` through the second-to-last `end` of the file (i.e. everything between that describe block's start and the final `end` that closes `defmodule CashLens.TransactionsTest`). Concretely: delete lines 902 through 1362 inclusive, leaving the file's last two lines as:

```elixir
  end
end
```

In `test/cash_lens/parsers/ingestor_test.exs`, inside the `describe "duplicate-safe re-import" do` block, remove these four tests (leave every other test in that describe block untouched):
- `"a file-imported row that duplicates an existing Pluggy transaction by account/date/amount is skipped"`
- `"a credit-card file import skips a Pluggy row dated one day off (the ±2 day window)"`
- `"a BANK account file import also skips a Pluggy row two days off (the ±2 day window applies to every account type)"`

(three tests, not four — re-check the file; there is no fourth). Also delete the two now-unused OFX fixture files these tests wrote at runtime — they're written and removed via `on_exit` in the tests themselves, so deleting the tests is sufficient, no separate fixture file cleanup needed.

- [ ] **Step 6: Fix the two stale doc-comment references to the deleted `Sync` module**

In `lib/cash_lens/pluggy.ex`, find the doc comment on `list_linked_account_links/0` mentioning `` `CashLens.Pluggy.Sync` `` and reword it to describe the new live-preview consumer instead, e.g.:

```elixir
  @doc """
  Links with an `account_id` already chosen — these are the ones the live
  Pluggy preview (`CashLens.Pluggy.LivePreview`) fetches transactions for.
  """
```

In `lib/cash_lens/transactions/transaction.ex`, find the comment above `defp put_default_source/1` that says:

```elixir
  # Callers that don't know or care about provenance (the manual "new
  # transaction" form, transfer-pair creation, income adjustments, transfer
  # mirrors) get a sensible default instead of having to pass `source`
  # everywhere. Importers that DO know their provenance (Ingestor -> "file",
  # Pluggy.Sync -> "pluggy") set it explicitly in their attrs and this is a
  # no-op for them.
```

and reword the last sentence to drop the now-nonexistent `Pluggy.Sync` reference, e.g.:

```elixir
  # Callers that don't know or care about provenance (the manual "new
  # transaction" form, transfer-pair creation, income adjustments, transfer
  # mirrors) get a sensible default instead of having to pass `source`
  # everywhere. Ingestor, which does know its provenance, sets `source:
  # "file"` explicitly and this is a no-op for it.
```

- [ ] **Step 7: Run the full test suite**

```bash
mix test
```

Expected: only the 3 known pre-existing failures in `test/cash_lens_web/live/installment_live_test.exs`. If anything else fails, it's almost certainly a stray reference to something deleted in this task — grep for `Pluggy.Sync`, `duplicate_from_other_source`, `duplicate_installment_from_other_source`, `cross_source` across `lib/` and `test/` and resolve every remaining hit before moving on.

- [ ] **Step 8: Format and commit**

```bash
mix format
git add -A
git commit -m "fix(pluggy): revert persisted Pluggy sync and cross-source dedup

Pluggy transactions never persisted successfully catch every real-world
case (a real PIX transaction was found entirely absent from Pluggy's
API response for an account/date range where it exists in the bank's
own CSV export) — no dedup logic can reconcile data one source simply
doesn't have. Pluggy becomes a read-only live preview instead (see
docs/superpowers/specs/2026-08-05-pluggy-live-preview-design.md)."
```

---

### Task 2: `CashLens.Pluggy.LivePreview` — fetch and normalize, no persistence

**Files:**
- Create: `lib/cash_lens/pluggy/live_preview.ex`
- Create: `lib/cash_lens/pluggy/live_preview/entry.ex`
- Modify: `lib/cash_lens/transactions.ex` (new public function)
- Test: `test/cash_lens/pluggy/live_preview_test.exs`
- Test: `test/cash_lens/transactions_test.exs` (new test for the new function)

**Interfaces:**
- Consumes: `CashLens.Pluggy.list_linked_account_links/0` (existing, unchanged — returns `AccountLink` structs preloaded with `:account` and `:pluggy_item`, each with a non-nil `account_id`). `CashLens.Pluggy.Client.auth/3`, `list_transactions/4` (existing, unchanged).
- Produces: `CashLens.Pluggy.LivePreview.Entry` struct: `%Entry{id: String.t(), account_id: Ecto.UUID.t(), date: Date.t(), description: String.t(), amount: Decimal.t(), pluggy_category: String.t() | nil}`. `CashLens.Pluggy.LivePreview.fetch_all/1 :: {:ok, %{Ecto.UUID.t() => [Entry.t()]}} | {:error, :missing_credentials | term()}` — the map is keyed by `account_id`, every linked account present as a key (empty list value on that account's own fetch failure). `CashLens.Transactions.latest_transaction_date/1 :: Date.t() | nil`.

- [ ] **Step 1: Write the failing test for `Transactions.latest_transaction_date/1`**

Add to `test/cash_lens/transactions_test.exs` (a new top-level `describe`, anywhere after the `alias`/`import` lines at the top of the file):

```elixir
  describe "latest_transaction_date/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "returns the most recent date among the account's transactions" do
      account = account_fixture()

      transaction_fixture(%{account_id: account.id, date: ~D[2026-01-10], amount: "-10"})
      transaction_fixture(%{account_id: account.id, date: ~D[2026-03-05], amount: "-20"})
      transaction_fixture(%{account_id: account.id, date: ~D[2026-02-01], amount: "-30"})

      assert Transactions.latest_transaction_date(account.id) == ~D[2026-03-05]
    end

    test "returns nil when the account has no transactions" do
      account = account_fixture()

      assert Transactions.latest_transaction_date(account.id) == nil
    end
  end
```

- [ ] **Step 2: Run it to see it fail**

```bash
mix test test/cash_lens/transactions_test.exs -v
```

Expected: FAIL with `UndefinedFunctionError` for `CashLens.Transactions.latest_transaction_date/1`.

- [ ] **Step 3: Implement `latest_transaction_date/1`**

In `lib/cash_lens/transactions.ex`, add this public function right after `defp get_latest_transaction_date do ... end` (the private, global-scope version it's named similarly to but distinct from — do not rename or touch the private one):

```elixir
  @doc """
  Returns the most recent transaction date for `account_id`, or `nil` if the
  account has no transactions at all.
  """
  @spec latest_transaction_date(Ecto.UUID.t()) :: Date.t() | nil
  def latest_transaction_date(account_id) do
    Repo.one(from t in Transaction, where: t.account_id == ^account_id, select: max(t.date))
  end
```

- [ ] **Step 4: Run it to see it pass**

```bash
mix test test/cash_lens/transactions_test.exs -v
```

Expected: PASS.

- [ ] **Step 5: Write the failing tests for `LivePreview`**

Create `test/cash_lens/pluggy/live_preview_test.exs`:

```elixir
defmodule CashLens.Pluggy.LivePreviewTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Pluggy
  alias CashLens.Pluggy.LivePreview

  setup do
    System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
    System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")

    on_exit(fn ->
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")
    end)

    %{req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
  end

  describe "fetch_all/1" do
    test "returns normalized entries for every linked account, keyed by account_id", %{
      req_options: req_options
    } do
      account = account_fixture()
      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "tx-1",
                  "date" => "2026-07-15T15:00:00.000Z",
                  "description" => "MERCADO XYZ",
                  "amount" => -42.5,
                  "type" => "DEBIT",
                  "category" => "Supermarket"
                }
              ],
              "next" => nil
            })
        end
      end)

      assert {:ok, entries_by_account} = LivePreview.fetch_all(req_options)
      assert [%LivePreview.Entry{} = entry] = entries_by_account[link.account_id]
      assert entry.id == "pluggy-preview-tx-1"
      assert entry.account_id == account.id
      assert entry.date == ~D[2026-07-15]
      assert entry.description == "MERCADO XYZ"
      assert Decimal.equal?(entry.amount, Decimal.new("-42.5"))
      assert entry.pluggy_category == "Supermarket"
    end

    test "fetches from the account's latest transaction date, not a fixed lookback", %{
      req_options: req_options
    } do
      account = account_fixture()
      transaction_fixture(%{account_id: account.id, date: ~D[2026-06-01], amount: "-10"})

      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      test_pid = self()

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            send(test_pid, {:from_date, conn.query_params["from"]})
            Req.Test.json(conn, %{"results" => [], "next" => nil})
        end
      end)

      assert {:ok, %{^link_account_id_placeholder => []}} = LivePreview.fetch_all(req_options)
      assert_received {:from_date, "2026-06-01"}
    end

    test "one account's fetch failure yields an empty list for it without affecting others", %{
      req_options: req_options
    } do
      account_a = account_fixture()
      account_b = account_fixture()
      item = pluggy_item_fixture()

      {:ok, link_a} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-a",
          pluggy_account_name: "Conta A",
          pluggy_account_type: "BANK"
        })

      {:ok, link_a} = Pluggy.link_account(link_a, account_a.id)

      {:ok, link_b} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-b",
          pluggy_account_name: "Conta B",
          pluggy_account_type: "BANK"
        })

      {:ok, link_b} = Pluggy.link_account(link_b, account_b.id)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            if conn.query_params["accountId"] == "acc-a" do
              conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
            else
              Req.Test.json(conn, %{"results" => [], "next" => nil})
            end
        end
      end)

      assert {:ok, entries_by_account} = LivePreview.fetch_all(req_options)
      assert entries_by_account[link_a.account_id] == []
      assert entries_by_account[link_b.account_id] == []
    end

    test "returns {:error, :missing_credentials} when env vars are unset" do
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")

      assert {:error, :missing_credentials} = LivePreview.fetch_all()
    end
  end
end
```

Before running, fix the placeholder `^link_account_id_placeholder` in the second test — it was left as a reminder that you need the real `link.account_id` bound in scope; replace that whole assertion line with:

```elixir
      {:ok, entries_by_account} = LivePreview.fetch_all(req_options)
      assert entries_by_account[link.account_id] == []
```

(binding `link` from the earlier `{:ok, link} = Pluggy.link_account(link, account.id)` call already in that test).

- [ ] **Step 6: Run tests to verify they fail**

```bash
mix test test/cash_lens/pluggy/live_preview_test.exs -v
```

Expected: FAIL — the `CashLens.Pluggy.LivePreview` module does not exist yet.

- [ ] **Step 7: Implement the `Entry` struct**

Create `lib/cash_lens/pluggy/live_preview/entry.ex`:

```elixir
defmodule CashLens.Pluggy.LivePreview.Entry do
  @moduledoc """
  One unsaved, live-fetched Pluggy transaction. Never an `Ecto.Schema`, never
  inserted — `CashLens.Pluggy.LivePreview.fetch_all/1` is the only producer.

  `id` is a synthetic, stable-per-real-world-transaction string (derived from
  Pluggy's own transaction id), not a database id — it exists so
  `Phoenix.LiveView.stream_insert/3` can update an entry cleanly across
  refreshes instead of treating every refresh as brand new rows.
  """

  @enforce_keys [:id, :account_id, :date, :description, :amount]
  defstruct [:id, :account_id, :date, :description, :amount, :pluggy_category]

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: Ecto.UUID.t(),
          date: Date.t(),
          description: String.t(),
          amount: Decimal.t(),
          pluggy_category: String.t() | nil
        }
end
```

- [ ] **Step 8: Implement `CashLens.Pluggy.LivePreview`**

Create `lib/cash_lens/pluggy/live_preview.ex`:

```elixir
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

  defp from_date(account_id) do
    case Transactions.latest_transaction_date(account_id) do
      nil -> Date.add(Date.utc_today(), -@default_lookback_days)
      date -> date
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
```

- [ ] **Step 9: Run tests to verify they pass**

```bash
mix test test/cash_lens/pluggy/live_preview_test.exs -v
```

Expected: PASS, all 4 tests.

- [ ] **Step 10: Run the full test suite**

```bash
mix test
```

Expected: only the 3 known pre-existing `installment_live_test.exs` failures.

- [ ] **Step 11: Format and commit**

```bash
mix format
git add lib/cash_lens/pluggy/live_preview.ex lib/cash_lens/pluggy/live_preview/entry.ex \
  lib/cash_lens/transactions.ex test/cash_lens/pluggy/live_preview_test.exs \
  test/cash_lens/transactions_test.exs
git commit -m "feat(pluggy): add LivePreview — fetches and normalizes without persisting"
```

---

### Task 3: `CashLens.Pluggy.LivePreviewCache` — in-memory GenServer

**Files:**
- Create: `lib/cash_lens/pluggy/live_preview_cache.ex`
- Modify: `lib/cash_lens/application.ex`
- Test: `test/cash_lens/pluggy/live_preview_cache_test.exs`

**Interfaces:**
- Consumes: `CashLens.Pluggy.LivePreview.fetch_all/1` (Task 2) — actually called via `Application.get_env(:cash_lens, :pluggy_live_preview, CashLens.Pluggy.LivePreview)` so tests can substitute a stub module, exactly like the existing `:auto_categorizer` config-swap pattern used in `lib/cash_lens/parsers/ingestor.ex:384` and the (now-deleted) `Sync` module.
- Produces: `CashLens.Pluggy.LivePreviewCache.get_entries/1 :: [Entry.t()]`, `get_all_entries/0 :: [Entry.t()]`, `get_status/0 :: {:ok, DateTime.t()} | {:error, term(), DateTime.t() | nil}`, `refresh_now/0 :: :ok` — all used by Task 4 and Task 5.

- [ ] **Step 1: Write the failing tests**

Create `test/cash_lens/pluggy/live_preview_cache_test.exs`:

```elixir
defmodule CashLens.Pluggy.LivePreviewCacheTest do
  use ExUnit.Case, async: false

  alias CashLens.Pluggy.LivePreview.Entry
  alias CashLens.Pluggy.LivePreviewCache

  defmodule StubLivePreview do
    def fetch_all(_req_options \\ []) do
      case Process.get(:stub_result) do
        nil -> {:ok, %{}}
        result -> result
      end
    end
  end

  setup do
    Application.put_env(:cash_lens, :pluggy_live_preview, StubLivePreview)
    Process.put(:stub_result, nil)

    on_exit(fn ->
      Application.delete_env(:cash_lens, :pluggy_live_preview)
    end)

    :ok
  end

  test "starts with an :ok status and an immediate fetch" do
    account_id = Ecto.UUID.generate()

    entry = %Entry{
      id: "pluggy-preview-1",
      account_id: account_id,
      date: ~D[2026-07-01],
      description: "TEST",
      amount: Decimal.new("-10.00")
    }

    Process.put(:stub_result, {:ok, %{account_id => [entry]}})

    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_1})

    :sys.get_state(pid)

    assert {:ok, %DateTime{}} = LivePreviewCache.get_status(pid)
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]
    assert LivePreviewCache.get_all_entries(pid) == [entry]
  end

  test "refresh_now/0 triggers an out-of-band refresh with the latest stub result" do
    account_id = Ecto.UUID.generate()
    Process.put(:stub_result, {:ok, %{account_id => []}})

    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_2})
    :sys.get_state(pid)

    entry = %Entry{
      id: "pluggy-preview-2",
      account_id: account_id,
      date: ~D[2026-07-02],
      description: "NEW",
      amount: Decimal.new("-5.00")
    }

    Process.put(:stub_result, {:ok, %{account_id => [entry]}})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

    assert LivePreviewCache.get_entries(pid, account_id) == [entry]
  end

  test "a total failure sets an :error status while keeping the previous entries and last success time" do
    account_id = Ecto.UUID.generate()

    entry = %Entry{
      id: "pluggy-preview-3",
      account_id: account_id,
      date: ~D[2026-07-01],
      description: "TEST",
      amount: Decimal.new("-10.00")
    }

    Process.put(:stub_result, {:ok, %{account_id => [entry]}})
    {:ok, pid} = start_supervised({LivePreviewCache, name: :test_cache_3})
    :sys.get_state(pid)

    {:ok, first_success_at} = LivePreviewCache.get_status(pid)

    Process.put(:stub_result, {:error, :missing_credentials})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

    assert {:error, :missing_credentials, ^first_success_at} = LivePreviewCache.get_status(pid)
    # Entries from the last successful fetch are still served.
    assert LivePreviewCache.get_entries(pid, account_id) == [entry]

    Process.put(:stub_result, {:ok, %{account_id => []}})
    LivePreviewCache.refresh_now(pid)
    :sys.get_state(pid)

    assert {:ok, second_success_at} = LivePreviewCache.get_status(pid)
    assert DateTime.compare(second_success_at, first_success_at) != :lt
  end
end
```

- [ ] **Step 2: Run tests to see them fail**

```bash
mix test test/cash_lens/pluggy/live_preview_cache_test.exs -v
```

Expected: FAIL — `CashLens.Pluggy.LivePreviewCache` does not exist.

- [ ] **Step 3: Implement `LivePreviewCache`**

Create `lib/cash_lens/pluggy/live_preview_cache.ex`:

```elixir
defmodule CashLens.Pluggy.LivePreviewCache do
  @moduledoc """
  In-memory cache of the latest `CashLens.Pluggy.LivePreview.fetch_all/1`
  result. Refreshes every #{div(:timer.minutes(30), 60_000)} minutes on a
  timer, and on demand via `refresh_now/1`. Never touches the database —
  this is purely process state, lost on restart (which is fine: the next
  scheduled or manual refresh repopulates it).
  """

  use GenServer
  require Logger

  @refresh_interval :timer.minutes(30)

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Entries for one account, `[]` if none cached yet or that account has no live data."
  def get_entries(server \\ __MODULE__, account_id) do
    GenServer.call(server, {:get_entries, account_id})
  end

  @doc "Every cached entry across every account, flattened."
  def get_all_entries(server \\ __MODULE__) do
    GenServer.call(server, :get_all_entries)
  end

  @doc """
  `{:ok, last_refreshed_at}` after a successful fetch, or
  `{:error, reason, last_success_at}` (where `last_success_at` is `nil` if
  there has never been a successful fetch) after a total failure.
  """
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  @doc "Triggers an immediate out-of-band refresh, not waiting for the timer."
  def refresh_now(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    send(self(), :refresh)
    {:ok, %{entries: %{}, status: {:error, :not_yet_fetched, nil}}}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call({:get_entries, account_id}, _from, state) do
    {:reply, Map.get(state.entries, account_id, []), state}
  end

  @impl true
  def handle_call(:get_all_entries, _from, state) do
    {:reply, state.entries |> Map.values() |> List.flatten(), state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  defp do_refresh(state) do
    live_preview = Application.get_env(:cash_lens, :pluggy_live_preview, CashLens.Pluggy.LivePreview)

    case live_preview.fetch_all() do
      {:ok, entries} ->
        %{entries: entries, status: {:ok, DateTime.utc_now()}}

      {:error, reason} ->
        Logger.warning("Pluggy live preview cache: refresh failed: #{inspect(reason)}")
        %{state | status: {:error, reason, last_success_at(state.status)}}
    end
  end

  defp last_success_at({:ok, at}), do: at
  defp last_success_at({:error, _reason, at}), do: at

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cash_lens/pluggy/live_preview_cache_test.exs -v
```

Expected: PASS, all 3 tests.

- [ ] **Step 5: Add the cache to the application supervision tree**

In `lib/cash_lens/application.ex`, add `CashLens.Pluggy.LivePreviewCache` to the `children` list, after `CashLens.Repo` (it doesn't strictly depend on Repo, but keeping it near other app-level singletons and before the Endpoint is the natural place):

```elixir
    children = [
      CashLensWeb.Telemetry,
      CashLens.Repo,
      {DNSCluster, query: Application.get_env(:cash_lens, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CashLens.PubSub},
      {Oban, Application.fetch_env!(:cash_lens, Oban)},
      CashLens.Pluggy.LivePreviewCache,
      # Start a worker by calling: CashLens.Worker.start_link(arg)
      # {CashLens.Worker, arg},
      # Start to serve requests, typically the last entry
      CashLensWeb.Endpoint
    ]
```

- [ ] **Step 6: Run the full test suite**

```bash
mix test
```

Expected: only the 3 known pre-existing `installment_live_test.exs` failures. The cache now starts for real in the test environment too (via `CashLens.Application`), immediately triggering a real `fetch_all/0` on boot — since `PLUGGY_CLIENT_ID`/`PLUGGY_CLIENT_SECRET` are not set in `test.exs` by default outside the specific tests that set them, this resolves to `{:error, :missing_credentials}` harmlessly (logged, not raised) and does not affect any other test's outcome. If you see unexpected log noise from this in an unrelated test's output, that's expected and not a failure — do not suppress it by changing test config as part of this task.

- [ ] **Step 7: Format and commit**

```bash
mix format
git add lib/cash_lens/pluggy/live_preview_cache.ex lib/cash_lens/application.ex \
  test/cash_lens/pluggy/live_preview_cache_test.exs
git commit -m "feat(pluggy): add LivePreviewCache GenServer with 30-minute refresh"
```

---

### Task 4: Wire "Sincronizar Tudo" to also trigger a live-preview refresh

**Files:**
- Modify: `lib/cash_lens_web/live/pluggy_live/index.ex`
- Test: `test/cash_lens_web/live/pluggy_live/index_test.exs`

**Interfaces:**
- Consumes: `CashLens.Pluggy.LivePreviewCache.refresh_now/0` (Task 3).

**Context:** "Sincronizar Tudo" on `/pluggy` (`handle_event("sync_all_items", ...)`) refreshes each Pluggy *item*'s list of *accounts* (for the account-mapping dropdown) — this is unrelated to transaction persistence and is **not** being removed or replaced; it keeps working exactly as it does today. This task only *adds* a live-preview cache refresh alongside it, since the user asked for the cache to also refresh "quando clicar no sincronizar tudo."

- [ ] **Step 1: Write the failing test**

In `test/cash_lens_web/live/pluggy_live/index_test.exs`, find the `describe "syncing all items at once"` block and add this test inside it (it needs a way to observe that the cache was told to refresh — use the same `StubLivePreview` config-swap approach as Task 3's cache test, since asserting on real Pluggy HTTP calls here would conflate two different concerns):

```elixir
    test "also triggers a live-preview cache refresh", %{conn: conn} do
      test_pid = self()

      Application.put_env(:cash_lens, :pluggy_live_preview, %{
        fetch_all: fn -> send(test_pid, :fetch_all_called) end
      })

      on_exit(fn -> Application.delete_env(:cash_lens, :pluggy_live_preview) end)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" -> Req.Test.json(conn, %{"apiKey" => "test-key"})
          "/accounts" -> Req.Test.json(conn, %{"results" => []})
        end
      end)

      {:ok, live, _html} = live(conn, ~p"/pluggy")
      render_click(live, "sync_all_items", %{})

      assert_receive :fetch_all_called, 1000
    end
```

Read this test skeptically before running it — a bare `%{fetch_all: fn -> ... end}` map is not a real module and `LivePreviewCache`'s `Application.get_env(:cash_lens, :pluggy_live_preview, CashLens.Pluggy.LivePreview)` calls `live_preview.fetch_all()` as a *module* function call, which will not work against a map. Fix this before running: instead, define a tiny named stub module inline in the test file (above the `describe` block, or as a top-level module in the file) exactly like `StubLivePreview` in Task 3's `live_preview_cache_test.exs`:

```elixir
  defmodule StubLivePreview do
    def fetch_all(_req_options \\ []) do
      send(Application.get_env(:cash_lens, :pluggy_live_preview_test_pid), :fetch_all_called)
      {:ok, %{}}
    end
  end
```

and in the test, set both `Application.put_env(:cash_lens, :pluggy_live_preview, StubLivePreview)` and `Application.put_env(:cash_lens, :pluggy_live_preview_test_pid, test_pid)`, cleaning both up in `on_exit`. This indirection (env-stashed pid) is necessary because the real `LivePreviewCache` GenServer process — not the test process — is the one that calls `fetch_all/0`.

- [ ] **Step 2: Run the test to see it fail**

```bash
mix test test/cash_lens_web/live/pluggy_live/index_test.exs -v
```

Expected: FAIL — `sync_all_items` doesn't call the cache yet, so `:fetch_all_called` is never received (timeout).

- [ ] **Step 3: Implement**

In `lib/cash_lens_web/live/pluggy_live/index.ex`, add the alias:

```elixir
  alias CashLens.Pluggy.LivePreviewCache
```

Then, inside `handle_event("sync_all_items", _params, socket)`, add one line — `LivePreviewCache.refresh_now()` — right before the existing `{:noreply, socket |> load_items() |> put_flash(flash_kind, message)}` line in the `with` block's success branch:

```elixir
  @impl true
  def handle_event("sync_all_items", _params, socket) do
    req_options = Application.get_env(:cash_lens, :pluggy_req_options, [])

    with {:ok, client_id, client_secret} <- fetch_credentials(),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options) do
      results =
        Enum.map(Pluggy.list_items(), fn item ->
          sync_item_accounts(item, api_key, req_options)
        end)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      failed_count = length(results) - ok_count

      message =
        "#{ok_count} item(ns) sincronizado(s)" <>
          if(failed_count > 0, do: ", #{failed_count} falharam.", else: ".")

      flash_kind = if failed_count > 0, do: :error, else: :success

      LivePreviewCache.refresh_now()

      {:noreply, socket |> load_items() |> put_flash(flash_kind, message)}
    else
      {:error, :missing_credentials} ->
        {:noreply,
         put_flash(socket, :error, "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao autenticar no Pluggy.")}
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/cash_lens_web/live/pluggy_live/index_test.exs -v
```

Expected: PASS, all tests in the file (the new one plus every pre-existing one, unaffected).

- [ ] **Step 5: Run the full test suite**

```bash
mix test
```

Expected: only the 3 known pre-existing `installment_live_test.exs` failures.

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/cash_lens_web/live/pluggy_live/index.ex test/cash_lens_web/live/pluggy_live/index_test.exs
git commit -m "feat(pluggy): trigger a live-preview cache refresh from Sincronizar Tudo"
```

---

### Task 5: Show live-preview entries on Transactions page 1

**Files:**
- Modify: `lib/cash_lens_web/live/transaction_live/index.ex`
- Modify: `lib/cash_lens_web/live/transaction_live/index.html.heex`
- Test: `test/cash_lens_web/live/transaction_live/index_test.exs`

**Interfaces:**
- Consumes: `CashLens.Pluggy.LivePreviewCache.get_all_entries/0`, `get_entries/1`, `get_status/0` (Task 3). `CashLens.Pluggy.LivePreview.Entry` struct (Task 2).
- Produces: nothing consumed elsewhere in this plan — this is the last task.

**Context:** `TransactionLive.Index` currently has ~9 call sites that each independently do `Transactions.list_transactions(map_filters(filters), 1)` followed by `stream(:transactions, ..., reset: true)` (in `handle_params/3` and various filter-change `handle_event` clauses). This task consolidates all of them into one shared private helper — both because duplicating the live-preview merge logic 9 times would be a maintenance trap, and because a fresh reviewer could otherwise reasonably reject "why does only `handle_params` get live entries and none of the filter handlers?" This is a mechanical, behavior-preserving consolidation for the 9 existing call sites (verified by the existing test suite staying green), with the one new behavior (live entries) added once, centrally.

- [ ] **Step 1: Write the failing tests**

In `test/cash_lens_web/live/transaction_live/index_test.exs`, add a new `describe` block (check the top of the file for its existing `alias`/`import` lines and reuse them rather than re-aliasing):

```elixir
  describe "Pluggy live preview" do
    setup do
      Application.put_env(:cash_lens, :pluggy_live_preview_cache, CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache)
      on_exit(fn -> Application.delete_env(:cash_lens, :pluggy_live_preview_cache) end)
      :ok
    end

    test "a live entry for the current account renders with the temporary-row marker and sums into the total",
         %{conn: conn} do
      account = account_fixture()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-1",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "COMPRA TEMPORARIA",
        amount: Decimal.new("-25.00")
      }

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{account.id => [entry]})
      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "COMPRA TEMPORARIA"
      assert html =~ "pluggy-preview-live-entry"
    end

    test "an error status shows a non-dismissing banner naming the failure", %{conn: conn} do
      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{})

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status(
        {:error, :missing_credentials, nil}
      )

      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "Não foi possível atualizar dados do Pluggy"
    end

    test "live entries are excluded when a category filter is active", %{conn: conn} do
      account = account_fixture()
      category = category_fixture()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-2",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "NAO DEVE APARECER",
        amount: Decimal.new("-25.00")
      }

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{account.id => [entry]})
      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, live, _html} = live(conn, ~p"/transactions")
      html = render_patch(live, ~p"/transactions?category_id=#{category.id}")

      refute html =~ "NAO DEVE APARECER"
    end
  end
```

Immediately above `defmodule CashLensWeb.TransactionLive.IndexTest do` in the same file, add the fake cache module the tests above reference (a real `Agent`-backed stand-in, not a `LivePreviewCache` GenServer, so tests can freely set state without racing the app's real 30-minute-timer instance):

```elixir
defmodule CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache do
  @moduledoc false
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{entries: %{}, status: {:ok, DateTime.utc_now()}} end, name: __MODULE__)
  end

  def set_entries(entries) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :entries, entries))
  end

  def set_status(status) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :status, status))
  end

  def get_entries(account_id), do: Agent.get(__MODULE__, &Map.get(&1.entries, account_id, []))
  def get_all_entries, do: Agent.get(__MODULE__, & &1.entries) |> Map.values() |> List.flatten()
  def get_status, do: Agent.get(__MODULE__, & &1.status)

  defp ensure_started do
    case start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
mix test test/cash_lens_web/live/transaction_live/index_test.exs -v
```

Expected: FAIL — `TransactionLive.Index` doesn't consult any live-preview cache yet, so none of the three new assertions match.

- [ ] **Step 3: Add the config-swap indirection and the shared refresh helper in `TransactionLive.Index`**

In `lib/cash_lens_web/live/transaction_live/index.ex`, add the alias:

```elixir
  alias CashLens.Pluggy.LivePreview
  alias CashLens.Pluggy.LivePreviewCache
```

Add a module attribute right after the `use CashLensWeb, :live_view` line for the config-swappable cache module (same pattern as `:auto_categorizer` elsewhere in this codebase — Task 4's test and this task's test both rely on being able to substitute a fake):

```elixir
  @live_preview_cache Application.compile_env(:cash_lens, :pluggy_live_preview_cache, LivePreviewCache)
```

Wait — `Application.compile_env/3` bakes the value in at compile time, which would prevent tests from swapping it per-test via `Application.put_env/3` in `setup`. Use a private function instead, resolved at call time:

```elixir
  defp live_preview_cache, do: Application.get_env(:cash_lens, :pluggy_live_preview_cache, LivePreviewCache)
```

Now replace **every** occurrence in the file of this exact 2-line pattern (there are ~9 of them, in `handle_params/3` and multiple `handle_event` clauses):

```elixir
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )
```

(and the one in `handle_params/3` which uses a pre-computed `txs` variable, and the one in `handle_event("import_pluggy", ...)` — already deleted in Task 1, so only ~8 remain by this point) — with a call to the new shared helper. Concretely:

1. Add this new private function, near `calculate_summary/1`:

```elixir
  defp refresh_transactions_page1(socket, filters) do
    db_transactions = Transactions.list_transactions(map_filters(filters), 1)
    {live_entries, pluggy_error} = live_preview_entries(filters)

    socket
    |> assign(:page, 1)
    |> assign(:end_of_list?, false)
    |> assign(:transfer_pairs, %{})
    |> assign(:pluggy_error, pluggy_error)
    |> calculate_summary()
    |> add_live_summary(live_entries)
    |> load_transfer_pairs(db_transactions)
    |> stream(:transactions, db_transactions, reset: true)
    |> insert_live_entries(live_entries)
  end

  defp insert_live_entries(socket, entries) do
    Enum.reduce(entries, socket, fn entry, acc -> stream_insert(acc, :transactions, entry) end)
  end

  defp add_live_summary(socket, []), do: socket

  defp add_live_summary(socket, live_entries) do
    live_income =
      live_entries
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))

    live_expenses =
      live_entries
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))

    update(socket, :summary, fn summary ->
      %{
        income: Decimal.add(summary.income, live_income),
        expenses: Decimal.add(summary.expenses, live_expenses)
      }
    end)
  end

  # `nil` filters (category, reimbursement status) that a live entry cannot
  # structurally have; if either is active, live entries are excluded
  # entirely rather than guessed at. Returns `{live_entries, pluggy_error}`
  # where `pluggy_error` is `nil` on a healthy cache, or
  # `{reason, last_success_at}` when the last refresh failed.
  defp live_preview_entries(filters) do
    case live_preview_cache().get_status() do
      {:ok, _at} ->
        {matching_live_entries(filters), nil}

      {:error, reason, last_success_at} ->
        {[], {reason, last_success_at}}
    end
  end

  defp matching_live_entries(filters) do
    if incompatible_filters_active?(filters) do
      []
    else
      filters
      |> live_entries_for_account_filter()
      |> Enum.filter(&matches_filters?(&1, filters))
    end
  end

  defp live_entries_for_account_filter(%{"account_id" => account_id})
       when account_id not in [nil, ""] do
    live_preview_cache().get_entries(account_id)
  end

  defp live_entries_for_account_filter(_filters), do: live_preview_cache().get_all_entries()

  defp incompatible_filters_active?(filters) do
    (filters["category_id"] || "") != "" or filters["reimbursement_status"] not in [nil, ""] or
      filters["unmatched_transfers"] == "true"
  end

  defp matches_filters?(entry, filters) do
    matches_search?(entry, filters["search"]) and
      matches_date?(entry, filters["date"]) and
      matches_date_range?(entry, filters["date_from"], filters["date_to"]) and
      matches_type?(entry, filters["type"])
  end

  defp matches_search?(_entry, search) when search in [nil, ""], do: true

  defp matches_search?(entry, search) do
    String.contains?(String.downcase(entry.description), String.downcase(search))
  end

  defp matches_date?(_entry, date) when date in [nil, ""], do: true

  defp matches_date?(entry, date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.compare(entry.date, parsed) == :eq
      _ -> true
    end
  end

  defp matches_date_range?(_entry, from, _to) when from in [nil, ""], do: true
  defp matches_date_range?(_entry, _from, to) when to in [nil, ""], do: true

  defp matches_date_range?(entry, from, to) do
    with {:ok, date_from} <- Date.from_iso8601(from),
         {:ok, date_to} <- Date.from_iso8601(to) do
      Date.compare(entry.date, date_from) != :lt and Date.compare(entry.date, date_to) != :gt
    else
      _ -> true
    end
  end

  defp matches_type?(_entry, type) when type not in ["debit", "expense", "credit", "income"],
    do: true

  defp matches_type?(entry, type) when type in ["debit", "expense"],
    do: Decimal.negative?(entry.amount)

  defp matches_type?(entry, type) when type in ["credit", "income"],
    do: Decimal.positive?(entry.amount)
```

2. Replace every 2-line `stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1), reset: true)` call (with whatever else immediately surrounds it in each handler — inspect each of the ~8 remaining call sites individually, they are not byte-identical, some also `assign(:page, 1)`/`assign(:end_of_list?, false)`/`calculate_summary()` inline) with a call to `refresh_transactions_page1(socket, new_filters)` (or `filters`, matching whatever variable name that handler already uses), dropping whichever of `assign(:page, 1)`, `assign(:end_of_list?, false)`, `assign(:transfer_pairs, %{})`, `calculate_summary()`, `load_transfer_pairs(...)` that handler was doing inline — they're now inside the helper. For example, `handle_params/3` becomes:

```elixir
  @impl true
  def handle_params(params, _url, socket) do
    {return_to, params} = Map.pop(params, "return_to")
    {open_import, filters_param} = Map.pop(params, "open_import")

    filters = Map.merge(socket.assigns.filters, filters_param || %{})

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:return_to, return_to)
      |> assign(:show_import_modal, open_import == "true")
      |> refresh_transactions_page1(filters)

    {:noreply, socket}
  end
```

Go through each remaining call site the same way — the reviewer for this task should read every one you touched and confirm nothing besides the duplicated fetch+stream logic was accidentally dropped (e.g. a handler that also does something unrelated like closing a modal must keep doing that).

- [ ] **Step 4: Add the error banner and the temporary-row marker to the template**

In `lib/cash_lens_web/live/transaction_live/index.html.heex`, add a banner near the top of the page (immediately after the `<.header>` block, or wherever the existing flash/header markup ends — place it so it's visually above the transaction table):

```heex
      <div
        :if={@pluggy_error}
        class="alert alert-error mb-4"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          Não foi possível atualizar dados do Pluggy: {inspect(elem(@pluggy_error, 0))}.
          <%= if elem(@pluggy_error, 1) do %>
            Última atualização bem-sucedida: {Calendar.strftime(elem(@pluggy_error, 1), "%d/%m %H:%M")}.
          <% else %>
            Nunca houve uma atualização bem-sucedida.
          <% end %>
          Mostrando apenas dados já salvos.
        </span>
      </div>
```

This is a plain conditional `<div>` driven by the `@pluggy_error` assign, deliberately **not** the app's shared `<.flash>` component — that component's `phx-hook="FlashAutoClose"` (`lib/cash_lens_web/components/core_components.ex:30`) auto-dismisses every flash after a few seconds regardless of kind, and this banner must persist across the whole session until the next successful refresh clears `@pluggy_error` back to `nil` (which already happens naturally: `refresh_transactions_page1/2` recomputes `pluggy_error` from the cache's current status on every page-1 refresh).

For the row marker, find the `<tr :for={{id, transaction} <- @streams.transactions} ...>` block. Add a branch at the very top of that `<tr>`'s body distinguishing a `%LivePreview.Entry{}` from a real `%Transaction{}`, and a distinct, minimal row for the former. The existing row's full body (date/description/amount/category/actions/etc.) stays exactly as it is for real transactions — wrap it:

```heex
            <tr
              :for={{id, transaction} <- @streams.transactions}
              id={id}
              class={[
                "hover group border-b border-base-200 overflow-visible",
                match?(%LivePreview.Entry{}, transaction) && "bg-warning/10 pluggy-preview-live-entry",
                Map.get(transaction, :transfer_key) && "border-l-2 border-l-secondary/50"
              ]}
            >
              <td :if={match?(%LivePreview.Entry{}, transaction)} colspan="6" class="px-4 py-2">
                <div class="flex items-center justify-between gap-2">
                  <div class="flex items-center gap-2 text-sm">
                    <.icon name="hero-clock" class="size-4 opacity-60" />
                    <span class="font-medium">{format_date(transaction.date)}</span>
                    <span>{transaction.description}</span>
                    <span class="badge badge-xs badge-warning">Temporário — não gravado</span>
                  </div>
                  <span class={[
                    "font-bold",
                    if(Decimal.lt?(transaction.amount, 0), do: "text-error", else: "text-success")
                  ]}>
                    {format_currency(transaction.amount)}
                  </span>
                </div>
              </td>
              <%= if not match?(%LivePreview.Entry{}, transaction) do %>
                <!-- existing <td> columns for a real transaction go here, unchanged -->
              <% end %>
            </tr>
```

The `Map.get(transaction, :transfer_key)` in the class list (instead of the original bare `transaction.transfer_key`) is required because `%LivePreview.Entry{}` has no `:transfer_key` field at all and would raise `KeyError` on direct dot-access — `Map.get/2` returns `nil` safely for a struct lacking that key. Move the entire existing block of `<td>` elements for a real transaction (everything currently between the opening `<tr ...>` and its closing `</tr>`) inside the `<%= if not match?(%LivePreview.Entry{}, transaction) do %> ... <% end %>` wrapper — do not rewrite or shorten that existing content, only relocate it inside the new conditional.

Add the alias the template needs at the top of `index.ex` if not already present from Step 3 (`alias CashLens.Pluggy.LivePreview` — already added above).

- [ ] **Step 5: Run the tests to verify they pass**

```bash
mix test test/cash_lens_web/live/transaction_live/index_test.exs -v
```

Expected: PASS, all tests in the file — both the 3 new ones and every pre-existing test in this large file (they exercise the ~8 consolidated call sites indirectly; a regression in the consolidation would show up here).

- [ ] **Step 6: Run the full test suite**

```bash
mix test
```

Expected: only the 3 known pre-existing `installment_live_test.exs` failures.

- [ ] **Step 7: Manually verify in the browser**

Start the dev server and confirm visually: a Pluggy-linked account with cached live entries shows them on `/transactions` page 1 with the warning-colored background and "Temporário — não gravado" badge, summed into the totals at the top; navigating to page 2 shows none; setting a category filter hides them; killing/misconfiguring Pluggy credentials and forcing a refresh (`LivePreviewCache.refresh_now/0` from an `iex -S mix` console, or waiting for the 30-minute timer) shows the persistent error banner.

- [ ] **Step 8: Format and commit**

```bash
mix format
git add lib/cash_lens_web/live/transaction_live/index.ex lib/cash_lens_web/live/transaction_live/index.html.heex \
  test/cash_lens_web/live/transaction_live/index_test.exs
git commit -m "feat(transactions): show Pluggy live-preview entries on page 1, marked temporary"
```

---

## Self-Review Notes

**Spec coverage:** Every section of `docs/superpowers/specs/2026-08-05-pluggy-live-preview-design.md` maps to a task — "What gets removed" → Task 1, "LivePreview" → Task 2, "Cache" → Task 3, "/pluggy screen changes" → Task 4, "TransactionLive.Index changes" (including the non-dismissing error banner) → Task 5. The spec's "Explicitly out of scope" section (dashboard, per-account toggle, CREDIT statement logic, data cleanup) has no corresponding task, correctly.

**Type consistency:** `Entry.t()` (Task 2) is the type threaded through `LivePreviewCache` (Task 3, stores and returns `[Entry.t()]`) and `TransactionLive.Index` (Task 5, pattern-matches `%LivePreview.Entry{}` in the template and Elixir filter functions) — the field names (`id`, `account_id`, `date`, `description`, `amount`, `pluggy_category`) are used consistently across all three tasks.

**Known follow-up, not in this plan:** Task 5's `matches_filters?/2` does not replicate `filter_by_amount/2`'s exact/near-integer-match semantics or `filter_by_amount_range/3` — an active amount filter simply doesn't exclude live entries (they pass through unfiltered on amount). This mirrors the spec's stated v1 scope ("filter... against whatever of the active filters they can structurally satisfy") loosely rather than exhaustively; tightening it is a reasonable future addition, not a defect blocking this plan.
