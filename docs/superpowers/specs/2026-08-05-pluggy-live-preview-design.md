# Pluggy Live Preview — Design

## Problem

The Pluggy Open Finance integration built earlier (feature branch merged into `master`, commits `2e0e496`..`2314992`) persists Pluggy transactions to the `transactions` table (`source: "pluggy"`), reconciled against file-imported data (`source: "file"`) via a cross-source dedup mechanism (date-tolerance windows, installment-identity matching).

Real-data testing against the user's own accounts (documented across this session) surfaced three classes of problems with that approach:

1. **Correctness bugs** in the Pluggy data itself, fixed during this session: an inverted amount sign for BANK accounts, a UTC-vs-BRT timezone bug, and several date-drift patterns (weekend/business-day settlement lag, credit-card late-night posting cutoff, unpredictable installment re-dating).
2. **A data completeness gap that cannot be fixed by better matching**: a real R$100 PIX RECEBIDO transaction, present in the Bradesco CSV export, is entirely absent from Pluggy's API response for the same account and date range. No dedup logic can reconcile data that one source simply does not have.
3. **Growing dedup complexity** (weekend tolerance, ±2 day windows, installment-parcel identity matching with a 60-day window and total-count checks) needed to compensate for (1), all of which becomes moot once Pluggy stops being a system of record.

Given (2) especially, Pluggy cannot be trusted as a sole source of truth for historical data. The user's decision: stop persisting Pluggy data entirely. Monthly file imports (CSV/OFX/PDF/TXT) remain the only way real transactions enter the database. Pluggy becomes a **read-only, in-memory preview** of the gap between the last real (persisted) transaction and today — useful for day-to-day visibility, never written to disk, never reconciled against real data.

## Goal (this spec)

Phase 1 only, by explicit user request ("vamos com calma", "vamos testar assim"): show Pluggy's live, unsaved transactions in the Transactions screen (`/transactions`), visually marked as temporary, without touching pagination, filtering, or summary calculation logic beyond what's described below. Dashboard/balance integration is explicitly out of scope for this spec — a future phase.

## What gets removed

Everything that exists solely to persist and reconcile Pluggy data:

- `CashLens.Pluggy.Sync.sync_all/1`, `sync_account_link/3`, `import_transaction/4`, and the CREDIT-account statement resolution helpers (`maybe_resolve_statement/3`, `resolve_statement/3`, `upsert_statement/4,5`) — the entire persist-and-reconcile path.
- The "Importar do Pluggy" button and `handle_event("import_pluggy", ...)` in `CashLensWeb.TransactionLive.Index`.
- `CashLens.Transactions.duplicate_from_other_source?/4` and `duplicate_installment_from_other_source?/5`, and their call sites in `CashLens.Parsers.Ingestor` (`cross_source_duplicate?/4`, the cross-source filtering step in `prepare_entries/3`, the `cross_source_skipped` accounting in `finalize_import/3`).
- The `"pluggy"` value as something ever written to `transactions.source` (the `source` column itself stays — `"file"` and `"manual"` remain meaningful).
- The `sync_accounts`/`sync_all_items` per-item "sincronizar contas" buttons on `/pluggy` in their current form — repurposed (see below), not deleted outright.
- Associated tests for all of the above.

## What stays

Everything the live preview still needs:

- `CashLens.Pluggy.Client` (`auth/3`, `list_accounts/3`, `list_transactions/4`) — unchanged.
- `CashLens.Pluggy.Item` / `CashLens.Pluggy.AccountLink` schemas and the `/pluggy` account-mapping screen — unchanged. `Pluggy.list_linked_account_links/0` (already filters to links with a non-nil `account_id`) becomes the single source of truth for "which accounts get a live preview" — **no new opt-in flag**. Any account already mapped in `/pluggy` gets one.
- `Sync.normalize_amount/2` (the corrected BANK/CREDIT sign logic) and the corrected `parse_date/1` (BRT timezone conversion) — both proven correct against real data this session, both required for the live fetch to show correct amounts and dates. These get extracted out of `Sync` (which is being deleted) into the new `LivePreview` module described below, or into a small shared helper module if reused by both — implementer's call at plan time, YAGNI-first (a single new module is simplest given `Sync` no longer exists to house them).

## New components

### `CashLens.Pluggy.LivePreview`

A new module, no persistence. For each account link returned by `Pluggy.list_linked_account_links/0`:

1. Determine the fetch window: `from_date = ` the account's own latest real (`source: "file"` or `"manual"`) transaction date, or 90 days back if the account has no transactions at all. `to_date` is always "today".
2. Fetch via `Client.list_transactions/4`.
3. Normalize each raw Pluggy transaction into a plain struct (not an `Ecto.Schema`, never inserted):

   ```elixir
   defmodule CashLens.Pluggy.LivePreview.Entry do
     defstruct [:id, :account_id, :date, :description, :amount, :pluggy_category]
   end
   ```

   `id` is a synthetic, stable-per-fetch value (e.g. `"pluggy-preview-" <> pluggy_transaction["id"]`, reusing Pluggy's own transaction id) so the same real-world transaction gets the same `id` across refreshes — needed later for `stream_insert`/`stream_delete` to update cleanly rather than flicker.
4. Returns `{:ok, %{account_id => [%Entry{}, ...]}}` on success for that account, or `{:error, reason}` — one account's failure must not abort the others (mirrors the existing `safe_sync_account_link/3` pattern from the deleted `Sync` module: catch and report per-account, not per-batch).

No dedup, no date-tolerance windows, no installment matching — the entries are never compared against stored data at all.

### Cache: `CashLens.Pluggy.LivePreviewCache` (GenServer)

- On a 30-minute timer, calls `LivePreview` for every linked account and stores the result.
- State shape: `%{entries: %{account_id => [%Entry{}, ...]}, status: {:ok, DateTime.t()} | {:error, term(), DateTime.t() | nil}}` — `status` records the outcome of the *last attempt* and, on error, the timestamp of the *last successful* refresh (`nil` if there has never been one), so the UI can say "showing saved data only" accurately.
- Public API: `get_entries(account_id) :: [Entry.t()]` (empty list if none cached or on error), `get_status() :: {:ok, DateTime.t()} | {:error, term(), DateTime.t() | nil}`, `refresh_now() :: :ok` (async-triggers an immediate fetch cycle, used by the repurposed "Sincronizar Tudo" button).
- A single account's fetch failure does not flip the whole cache to `:error` — only a total failure (e.g. can't authenticate at all) does. Partial success (some accounts fetched, one failed) keeps `status: {:ok, ...}` with only that account's entries stale/empty; this is a judgment call for the implementer to size correctly, not over-engineer (YAGNI: if `Client.auth/3` itself fails, nothing can be fetched, that's the one whole-cache failure mode worth modeling explicitly; a single account's `list_transactions` failing degrades that account's own entries only).

### `/pluggy` screen changes

- "Sincronizar Tudo" now calls `LivePreviewCache.refresh_now/0` instead of the deleted persist-based sync.
- Per-item "Sincronizar" (accounts-list refresh) stays as-is — that's about discovering/renaming Pluggy accounts for mapping, unrelated to transaction persistence, not touched by this spec.

### `CashLensWeb.TransactionLive.Index` changes

On `mount/3` and on every event that already re-fetches page 1 (`handle_params`, filter changes — every existing call site already listed above that does `stream(:transactions, Transactions.list_transactions(...), reset: true)`):

1. After the existing DB query for page 1 (page > 1 gets no live entries at all — this is the deliberate v1 boundary), call `LivePreviewCache.get_entries/1` for the account currently in scope (or all mapped accounts, if the filter has no account selected — implementer's call, follow whatever `map_filters/1` already does for "no account filter" today).
2. Filter the returned entries in Elixir against whatever of the *active* filters they can structurally satisfy: date range, account, free-text description match, amount range. If the active filters include anything a live entry cannot have — category, reimbursement status, transfer status, installment group — **skip merging live entries entirely for that render** (an entry with no category can never match a category filter; excluding all of them exactly reflects that, no partial-match heuristics needed).
3. `stream_insert(:transactions, entry)` each surviving entry into the same `:transactions` stream the real rows use, so they render in the same table via the existing row template. Entries are `%LivePreview.Entry{}` structs, not `%Transaction{}` — the row template needs a small branch (`case`/pattern on struct type, or a shared "is this virtual?" helper) to:
   - Render a distinct background (a CSS class, e.g. `bg-warning/10` or similar — exact styling is implementation detail, not a hex code to pin here).
   - Skip/hide row actions that only make sense for persisted rows (edit, delete, categorize, reimbursement, transfer linking) — a live entry has no `id` the rest of the app can act on.
4. Add the sum of the surviving live entries' amounts to whatever `calculate_summary/1` already produced for the DB page — a plain `Decimal.add/2`, no query changes.

On mount, also check `LivePreviewCache.get_status/0`. If it returns `{:error, reason, last_success_at}`, `put_flash(:error, ...)` with a message naming the failure and, if `last_success_at` is non-nil, when the last successful refresh was; if `nil`, that live preview has never succeeded. This flash must **not** auto-dismiss the way the app's normal flashes do — check how `CashLensWeb.Layouts`/the flash component currently handles auto-hide (likely a JS timeout or `phx-hook`) and either use a flash kind that's exempted from it already, or add one. It clears itself only when a subsequent mount/refresh observes `status: {:ok, ...}` again — it is not manually dismissible-and-gone in the sense of disappearing from future page loads if the underlying problem persists.

## Data flow

```
LivePreviewCache (GenServer, 30 min timer + manual refresh_now/0)
        |
        v  every cycle
  CashLens.Pluggy.LivePreview.fetch_all/0
        |  per account link
        v
  Client.list_transactions/4  --(raw Pluggy JSON)-->  normalize (sign + timezone)  -->  [%Entry{}]
        |
        v
  stored in GenServer state, keyed by account_id, plus overall {:ok|:error, ...} status

TransactionLive.Index (mount / page-1 filter changes only)
        |
        v
  Transactions.list_transactions/3 (DB, unchanged) --> page 1 real rows + summary
        |
        v
  LivePreviewCache.get_entries/1 --> filter in Elixir against active filters --> stream_insert alongside real rows, add to summary
        |
        v
  LivePreviewCache.get_status/0 --> put_flash(:error, ...) if the last fetch failed, non-dismissing
```

## Error handling

- `LivePreview.fetch_all/0`: one account's `Client.list_transactions/4` failure is caught and logged, contributes an empty entry list for that account, does not stop other accounts from being fetched (mirrors the deleted `Sync.safe_sync_account_link/3`'s isolation pattern — same shape of problem, same shape of fix).
- Total failure (can't `Client.auth/3` at all — missing/invalid credentials, Pluggy API down) sets cache `status: {:error, reason, last_success_at}`.
- `TransactionLive.Index` never lets a Pluggy failure break the page: `get_entries/1` and `get_status/0` are cache reads (GenServer `call` against already-computed state), not live API calls — a slow or down Pluggy API cannot make the Transactions screen itself slow or fail to render. Only the flash message surfaces the failure.

## Testing

- `CashLens.Pluggy.LivePreviewTest`: `fetch_all/0` against a stubbed `Client` (same `Req.Test` stubbing pattern already used throughout the existing Pluggy test suite) — correct sign/date normalization reused from the proven-correct logic, correct per-account isolation on partial failure, correct `from_date` derivation (latest real transaction vs. 90-day fallback for an account with no transactions yet).
- `CashLens.Pluggy.LivePreviewCacheTest`: refresh timer fires and updates state; `refresh_now/0` triggers an out-of-band refresh; a total failure sets `status: {:error, ...}` while preserving the previous `last_success_at`; a total failure followed by a success clears the error status.
- `CashLensWeb.TransactionLive.IndexTest` (new cases alongside the existing suite): live entries appear on page 1 with the distinct-background marker and sum into the total; live entries are absent on page 2; live entries are absent when a category or reimbursement filter is active; the non-dismissing error flash appears when the cache status is `:error` and disappears once it's `:ok` again.

## Explicitly out of scope for this spec

- Dashboard (`PageController.home/2`) / balance integration — a later phase, by the user's own request to go incrementally.
- Any UI for toggling live preview per-account — deliberately removed from scope; mapping in `/pluggy` is the only signal.
- CREDIT-account statement/fatura logic for the live preview (the deleted `Sync` module's `maybe_resolve_statement/3` and friends) — the live preview shows raw transactions only, no statement reconciliation, for any account type.
- Reconciling or deleting the (currently zero, confirmed earlier this session) `source: "pluggy"` rows in the real database — there are none to clean up, but the migration removing that value from being writable does not need a data backfill.
