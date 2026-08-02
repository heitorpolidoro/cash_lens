# Transaction Source + Cross-Source Dedup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `source` field to transactions and use it to detect duplicates across import sources (file vs. Pluggy) whose exact-fingerprint dedup fails because the same real-world charge has differently-worded descriptions depending on where it came from.

**Architecture:** A new `source` string column (`"file"`, `"pluggy"`, or `"manual"`) is stamped on every transaction at creation time, defaulted in `Transaction.changeset/2` so existing call sites don't need to change. A new `Transactions.duplicate_from_other_source?/4` query checks for an existing transaction in the same account, on the same date, for the same amount, but written by a *different* source — this is a looser, description-independent signal used *in addition to* (not instead of) the existing exact-fingerprint dedup. Both importers (`CashLens.Parsers.Ingestor` for file imports, `CashLens.Pluggy.Sync` for Pluggy) call it before inserting, so the check is symmetric regardless of which source runs first.

**Tech Stack:** Elixir 1.18, Phoenix, Ecto/Postgres, ExUnit.

## Global Constraints

- Every existing test must keep passing; the 3 pre-existing, unrelated failures in `test/cash_lens_web/live/installment_live_test.exs` (date-sensitive fixtures, not caused by this work) are the only acceptable failures in the final `mix test` run.
- `mix format` must pass (the repo's pre-commit hook runs `mix format --check-formatted`).
- Do not change the exact-fingerprint dedup behavior (`Transaction.dedup_key/1`, `fingerprint/2`) — the new check is additive, layered on top.
- `source` values are exactly one of `"file"`, `"pluggy"`, `"manual"` — validated with `validate_inclusion/3`.

---

### Task 1: Add the `source` column, schema field, and changeset default

**Files:**
- Create: `priv/repo/migrations/20260802130000_add_source_to_transactions.exs`
- Modify: `lib/cash_lens/transactions/transaction.ex`
- Test: `test/cash_lens/transactions/transaction_test.exs`

**Interfaces:**
- Produces: `Transaction` schema gains `field :source, :string`. `Transaction.changeset/2` casts `:source` and, when absent from `attrs`, defaults it to `"manual"`. Validated with `validate_inclusion(:source, ["file", "pluggy", "manual"])`.

- [ ] **Step 1: Write the failing changeset tests**

Add to `test/cash_lens/transactions/transaction_test.exs` (new `describe` block, place it after the existing `describe "changeset fingerprint"` block):

```elixir
  describe "source" do
    @account_id "22222222-2222-2222-2222-222222222222"

    test "defaults to \"manual\" when not provided" do
      changeset =
        Transaction.changeset(%Transaction{}, %{
          date: ~D[2026-02-23],
          description: "some description",
          amount: "120.5",
          account_id: @account_id
        })

      assert Ecto.Changeset.get_field(changeset, :source) == "manual"
    end

    test "keeps an explicitly provided source" do
      changeset =
        Transaction.changeset(%Transaction{}, %{
          date: ~D[2026-02-23],
          description: "some description",
          amount: "120.5",
          account_id: @account_id,
          source: "pluggy"
        })

      assert Ecto.Changeset.get_field(changeset, :source) == "pluggy"
    end

    test "rejects an unrecognized source" do
      changeset =
        Transaction.changeset(%Transaction{}, %{
          date: ~D[2026-02-23],
          description: "some description",
          amount: "120.5",
          account_id: @account_id,
          source: "carrier-pigeon"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).source
    end
  end
```

`errors_on/1` is already available in this file's test context via `CashLens.DataCase` (confirm by checking the top of the file for `use CashLens.DataCase`; if `errors_on/1` is not imported, add `import CashLens.DataCase, only: [errors_on: 1]` — but `CashLens.DataCase` already exposes it to every test that does `use CashLens.DataCase`, which this file already does).

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions/transaction_test.exs -v`
Expected: the 3 new tests FAIL — the first two because `:source` isn't cast yet (field doesn't exist on the struct), the third because there's nothing to reject.

- [ ] **Step 3: Create the migration**

```elixir
defmodule CashLens.Repo.Migrations.AddSourceToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :source, :string
    end

    execute(
      "UPDATE transactions SET source = CASE WHEN pluggy_category IS NOT NULL THEN 'pluggy' ELSE 'file' END WHERE source IS NULL",
      ""
    )
  end
end
```

The backfill treats every already-existing row without a `pluggy_category` as `"file"` (the historical import method for all pre-Pluggy data) and every row that already has a `pluggy_category` as `"pluggy"` (transactions created by the Pluggy sync feature before this change). A handful of manually-created or transfer-mirror rows will be mislabeled `"file"` by this heuristic — that's acceptable: the cross-source check in Task 2 only needs to avoid re-creating a charge that's already on the books, and mislabeling a manual entry as `"file"` still achieves that (worst case, it makes the loose check slightly more conservative, never less).

- [ ] **Step 4: Run the migration**

```bash
mix ecto.migrate
```

Expected: migration `20260802130000` runs successfully, no errors.

- [ ] **Step 5: Add the field and changeset default**

In `lib/cash_lens/transactions/transaction.ex`, add the field to the schema (place it near `:pluggy_category`, around line 31):

```elixir
    field :pluggy_category, :string
    field :source, :string
```

Add `:source` to the `cast/3` list in `changeset/2`:

```elixir
    |> cast(attrs, [
      :id,
      :date,
      :time,
      :description,
      :amount,
      :category_id,
      :account_id,
      :transfer_key,
      :reimbursement_status,
      :reimbursement_link_key,
      :notes,
      :pluggy_category,
      :source,
      :installment_group_id,
      :installment_number,
      :occurrence_index,
      :parent_transaction_id,
      :import_batch_id
    ])
    |> validate_required([:date, :description, :amount, :account_id])
    |> put_default_source()
    |> validate_inclusion(:source, ["file", "pluggy", "manual"])
    |> put_dedup_key()
    |> generate_fingerprint()
    |> unique_constraint(:fingerprint)
    |> foreign_key_constraint(:parent_transaction_id)
```

Add the new private function right after `changeset/2` (before `defp identity_attrs`):

```elixir
  # Callers that don't know or care about provenance (the manual "new
  # transaction" form, transfer-pair creation, income adjustments, transfer
  # mirrors) get a sensible default instead of having to pass `source`
  # everywhere. Importers that DO know their provenance (Ingestor -> "file",
  # Pluggy.Sync -> "pluggy") set it explicitly in their attrs and this is a
  # no-op for them.
  defp put_default_source(changeset) do
    if is_nil(get_field(changeset, :source)) do
      put_change(changeset, :source, "manual")
    else
      changeset
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions/transaction_test.exs -v`
Expected: PASS, all tests including the 3 new ones.

- [ ] **Step 7: Run the full test suite to check for fallout**

Run: `mix test 2>&1 | tail -30`
Expected: same pass count as before this task, modulo the 3 known pre-existing `installment_live_test.exs` failures. If any *other* test fails, read its assertion — it is almost certainly asserting on the full list of changeset `cast` fields or a full attrs map equality; adjust that test's expectation to include `source`.

- [ ] **Step 8: Commit**

```bash
git add priv/repo/migrations/20260802130000_add_source_to_transactions.exs \
  lib/cash_lens/transactions/transaction.ex \
  test/cash_lens/transactions/transaction_test.exs
git commit -m "feat(transactions): add source field with file/pluggy/manual provenance"
```

---

### Task 2: `Transactions.duplicate_from_other_source?/4`

**Files:**
- Modify: `lib/cash_lens/transactions.ex`
- Test: `test/cash_lens/transactions_test.exs`

**Interfaces:**
- Consumes: `Transaction` schema's new `:source` field (Task 1).
- Produces: `CashLens.Transactions.duplicate_from_other_source?(account_id :: Ecto.UUID.t(), date :: Date.t(), amount :: Decimal.t(), source :: String.t()) :: boolean()` — used by Task 3 (Pluggy Sync) and Task 4 (Ingestor).

- [ ] **Step 1: Write the failing test**

Check whether `test/cash_lens/transactions_test.exs` exists and its `describe` layout first:

```bash
grep -n "^describe\|^  describe" test/cash_lens/transactions_test.exs | head -5
```

Add a new `describe` block (anywhere at the top level of the module, following the file's existing style of `import CashLens.TransactionsFixtures` / `import CashLens.AccountsFixtures` if already imported at the top — reuse those, don't re-import):

```elixir
  describe "duplicate_from_other_source?/4" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "true when an existing transaction has the same account/date/amount but a different source" do
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-06-16],
        amount: "-14391.19",
        description: "Pagto cartão crédito - PLATINUM ESTILO VISA",
        source: "file"
      })

      assert Transactions.duplicate_from_other_source?(
               account.id,
               ~D[2026-06-16],
               Decimal.new("-14391.19"),
               "pluggy"
             )
    end

    test "false when the only match has the SAME source" do
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-06-16],
        amount: "-14391.19",
        description: "PGTO CARTAO     PLATINUM ESTILO VISA",
        source: "pluggy"
      })

      refute Transactions.duplicate_from_other_source?(
               account.id,
               ~D[2026-06-16],
               Decimal.new("-14391.19"),
               "pluggy"
             )
    end

    test "false when there is no matching account/date/amount at all" do
      account = account_fixture()

      refute Transactions.duplicate_from_other_source?(
               account.id,
               ~D[2026-06-16],
               Decimal.new("-14391.19"),
               "pluggy"
             )
    end

    test "false when date or amount differ, even with a different source" do
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-06-16],
        amount: "-14391.19",
        description: "Pagto cartão crédito - PLATINUM ESTILO VISA",
        source: "file"
      })

      refute Transactions.duplicate_from_other_source?(
               account.id,
               ~D[2026-06-17],
               Decimal.new("-14391.19"),
               "pluggy"
             )

      refute Transactions.duplicate_from_other_source?(
               account.id,
               ~D[2026-06-16],
               Decimal.new("-1.00"),
               "pluggy"
             )
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/transactions_test.exs -v --only describe:"duplicate_from_other_source?/4"` (or simply grep-run: `mix test test/cash_lens/transactions_test.exs`)
Expected: FAIL with `UndefinedFunctionError` — `CashLens.Transactions.duplicate_from_other_source?/4 is undefined`.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/transactions.ex`, near `create_transaction/1` (the natural place — before it, so the dedup helper is defined before its main caller in reading order):

```elixir
  @doc """
  Returns `true` when a transaction already exists for `account_id`, on
  `date`, for `amount`, but was recorded by a *different* `source`.

  This is a looser, description-independent dedup signal used in addition to
  the exact-fingerprint dedup (`Transaction.fingerprint/2`). It exists
  because the same real-world charge can arrive with genuinely different
  description text depending on where it was imported from — Pluggy's raw
  bank-provided description ("PGTO CARTAO     PLATINUM ESTILO VISA") versus
  the file parsers' human-formatted one ("Pagto cartão crédito - PLATINUM
  ESTILO VISA") — which makes the exact fingerprint (description included)
  never match across sources for the very same transaction. Case/diacritic
  normalization alone does not fix this: the two strings differ in actual
  wording, not just formatting.
  """
  @spec duplicate_from_other_source?(Ecto.UUID.t(), Date.t(), Decimal.t(), String.t()) ::
          boolean()
  def duplicate_from_other_source?(account_id, date, amount, source) do
    Repo.exists?(
      from t in Transaction,
        where:
          t.account_id == ^account_id and
            t.date == ^date and
            t.amount == ^amount and
            t.source != ^source
    )
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/transactions_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/transactions.ex test/cash_lens/transactions_test.exs
git commit -m "feat(transactions): add duplicate_from_other_source?/4 cross-source dedup check"
```

---

### Task 3: Wire the cross-source check into `CashLens.Pluggy.Sync`

**Files:**
- Modify: `lib/cash_lens/pluggy/sync.ex`
- Test: `test/cash_lens/pluggy/sync_test.exs`

**Interfaces:**
- Consumes: `Transactions.duplicate_from_other_source?/4` (Task 2).
- Produces: `import_transaction/4` returns `:skipped` (not `:created`) for cross-source duplicates; `sync_account_link/3`'s `%{created:, skipped:, errors:}` counts reflect this.

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens/pluggy/sync_test.exs`, inside the `describe "sync_account_link/2"` block (or its own new `describe` block right after it — check the file for the exact `describe` name/location of `sync_account_link/2` tests first with `grep -n 'describe "sync_account_link' test/cash_lens/pluggy/sync_test.exs`):

```elixir
  describe "cross-source dedup" do
    setup do
      account = CashLens.AccountsFixtures.account_fixture()
      item = CashLens.PluggyFixtures.pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      %{account: account, link: link, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    test "skips a Pluggy transaction that duplicates an existing file-sourced one with a different description",
         %{account: account, link: link, req_options: req_options} do
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-06-16],
        amount: "-14391.19",
        description: "Pagto cartão crédito - PLATINUM ESTILO VISA",
        source: "file"
      })

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "id" => "tx-1",
              "date" => "2026-06-16T15:00:00.000Z",
              "description" => "PGTO CARTAO     PLATINUM ESTILO VISA",
              "amount" => -14391.19,
              "type" => "DEBIT"
            }
          ],
          "next" => nil
        })
      end)

      assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert Repo.aggregate(Transaction, :count, :id, prefix: nil) == 1
    end
  end
```

(If `Repo.aggregate(Transaction, :count, :id, prefix: nil)` feels unfamiliar, use the simpler existing pattern from the file instead: `assert Repo.aggregate(Transaction, :count) == 1`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/pluggy/sync_test.exs -v`
Expected: FAIL — `{:ok, %{created: 1, skipped: 0, errors: 0}}` instead of the expected `{:ok, %{created: 0, skipped: 1, errors: 0}}`, and `Repo.aggregate(Transaction, :count) == 2`.

- [ ] **Step 3: Implement**

In `lib/cash_lens/pluggy/sync.ex`, modify `import_transaction/4`:

```elixir
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
    _exception -> :error
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/pluggy/sync_test.exs -v`
Expected: PASS, all tests in the file (this is the moment to catch any *other* existing test that now unexpectedly collides — see Step 5).

- [ ] **Step 5: Run the full sync_test.exs suite and fix any incidental collisions**

Run: `mix test test/cash_lens/pluggy -v`
Expected: all pass. If an unrelated existing test now fails with `created: 0, skipped: 1` where it previously expected `created: 1, skipped: 0`, it means that test's fixture setup happens to create a same-account/date/amount transaction with a different `source` than `"pluggy"` before the sync runs. Fix it by giving that fixture transaction `source: "pluggy"` explicitly (so it's the *same* source as the sync under test, which correctly does NOT trigger the cross-source check), not by weakening the new check.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/pluggy/sync.ex test/cash_lens/pluggy/sync_test.exs
git commit -m "fix(pluggy): skip Pluggy transactions that duplicate a file-sourced one by account/date/amount"
```

---

### Task 4: Wire the cross-source check into `CashLens.Parsers.Ingestor`

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex`
- Test: `test/cash_lens/parsers/ingestor_test.exs`

**Interfaces:**
- Consumes: `Transactions.duplicate_from_other_source?/4` (Task 2).
- Produces: `Ingestor.import_file/3` and `Ingestor.import_directory/2`'s `%{imported:, skipped:, failed:}` result now also counts file-import rows that duplicate an existing Pluggy-sourced transaction as `skipped` instead of `imported`.

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens/parsers/ingestor_test.exs`, inside (or right after) the existing `describe "duplicate-safe re-import"` block:

```elixir
    test "a file-imported row that duplicates an existing Pluggy transaction by account/date/amount is skipped" do
      account = account_fixture(parser_type: "bb_csv")

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-02-24],
        amount: "-150.00",
        description: "PGTO CARTAO BB MM OURO 24/02 SOME MERCHANT",
        source: "pluggy"
      })

      assert {:ok, %{imported: 2, skipped: 1}} = Ingestor.import_file(account, @bb_sample)

      # The BB MM OURO row (24/02, -150.00) was skipped as a cross-source
      # duplicate; only SALDO ANTERIOR/RENDE FACIL/PIX rows from the sample
      # made it in as brand-new file-sourced transactions.
      assert Repo.aggregate(Transaction, :count) == 3
    end
```

`@bb_sample` and `account_fixture/1` are already available in this `describe` block's imports (confirm by checking the surrounding `describe "duplicate-safe re-import"` block already does `import CashLens.AccountsFixtures` and references `Transaction`/`Repo` — reuse, don't re-import). The sample CSV (`test/support/fixtures/files/bb_sample.csv`) has 3 real transaction rows (`BB MM OURO` -150.00 on 24/02, `BB RENDE FACIL` +500.00 on 25/02, `TRANSFERENCIA PIX` -25.50 on 26/02); `SALDO ANTERIOR`/`SALDO DO DIA` are balance markers the CSV parser does not emit as transactions (confirmed by the existing `"dispatches to bb_csv parser"` test asserting `length(transactions) == 3`).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs -v`
Expected: FAIL — `{:ok, %{imported: 3, skipped: 0, failed: []}}` instead of `{:ok, %{imported: 2, skipped: 1}}`, and `Repo.aggregate(Transaction, :count) == 4`.

- [ ] **Step 3: Implement**

In `lib/cash_lens/parsers/ingestor.ex`:

1. Set `source: "file"` in `prepare_transaction_entry/5`:

```elixir
  defp prepare_transaction_entry(data, account_id, now, occurrence_index, statement_id) do
    categorizer = Application.get_env(:cash_lens, :auto_categorizer, AutoCategorizer)

    attrs =
      data
      |> Map.put(:account_id, account_id)
      |> Map.put(:occurrence_index, occurrence_index)
      |> Map.put(:source, "file")
      |> categorizer.categorize()

    # ...unchanged below...
```

2. Filter cross-source duplicates out of the prepared entries, and return their count so `finalize_import/3` can fold it into `skipped`. Change `prepare_entries/3`'s final lines:

```elixir
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

    all_entries = Enum.map(valid, fn {:ok, entry} -> entry end)
    reasons = Enum.map(failed, fn {:error, reason} -> reason end)

    {entries, cross_source_dupes} =
      Enum.split_with(all_entries, fn entry ->
        not CashLens.Transactions.duplicate_from_other_source?(
          entry.account_id,
          entry.date,
          entry.amount,
          "file"
        )
      end)

    {entries, reasons, length(cross_source_dupes)}
  end
```

3. Update `finalize_import/3`'s call site and `skipped` calculation:

```elixir
  defp finalize_import(transactions_data, account_id, statement_id) do
    # Never persist transactions dated in the future — they have not happened yet.
    today = Date.utc_today()
    transactions_data = Enum.reject(transactions_data, &(Date.compare(&1.date, today) == :gt))

    {entries, failed, cross_source_skipped} = prepare_entries(transactions_data, account_id, statement_id)

    {inserted_count, affected_account_ids} =
      process_entries(entries, transactions_data, account_id, statement_id)

    # Rebuild balances for all affected accounts up to the current month/year
    Enum.each(affected_account_ids, fn acc_id ->
      Accounting.rebuild_account_balances(acc_id)
    end)

    # `skipped` makes silent dedupe misses observable: it is the number of prepared
    # input rows that did not result in an insert — either the unique index rejected
    # them as already-present (or in-batch dups) via `fingerprint`, or they were
    # filtered out beforehand as a cross-source duplicate (see
    # `Transactions.duplicate_from_other_source?/4`).
    skipped = length(entries) - inserted_count + cross_source_skipped

    {:ok, %{imported: inserted_count, skipped: skipped, failed: failed}}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs -v`
Expected: PASS, all tests in the file.

- [ ] **Step 5: Run the full test suite**

Run: `mix test 2>&1 | tail -30`
Expected: same result as Task 1 Step 7 (only the 3 known pre-existing, unrelated `installment_live_test.exs` failures). If any other Ingestor test now unexpectedly reports a nonzero `skipped` it didn't before, it means that test's account/date/amount coincidentally collides with a fixture transaction of a different source created earlier in the same test — give that fixture `source: "file"` explicitly to match, exactly as in Task 3 Step 5.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/parsers/ingestor.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "fix(ingestor): skip file-imported rows that duplicate an existing Pluggy transaction by account/date/amount"
```

---

### Task 5: Final whole-branch review

- [ ] **Step 1: Read the full diff since the start of this plan**

```bash
git log --oneline -10
git diff 868dc89..HEAD -- lib/ test/
```

- [ ] **Step 2: Verify symmetry manually**

Confirm by reading the code (not just the tests) that:
- `CashLens.Pluggy.Sync.import_transaction/4` sets `source: "pluggy"` and calls `duplicate_from_other_source?/4` with `"pluggy"`.
- `CashLens.Parsers.Ingestor.prepare_transaction_entry/5` sets `source: "file"` and `prepare_entries/3` calls `duplicate_from_other_source?/4` with `"file"`.
- Both checks run *before* the row is ever handed to `Repo.insert`/`Repo.insert_all`, so a duplicate never touches the unique index — it's excluded upstream and counted as `skipped`.

- [ ] **Step 3: Re-run the original real-data dry run with the new logic**

Re-run the read-only dry-run script from the earlier manual test (`/private/tmp/.../scratchpad/pluggy_dry_run.exs`, still on disk) but this time make it call the real `CashLens.Transactions.duplicate_from_other_source?/4` in its "would insert" decision (in addition to the existing fingerprint check), instead of only checking `Repo.get_by(Transaction, fingerprint: fp)`. This does not insert anything — it is the same read-only comparison technique used earlier in this session. Report the new totals to the user: expect "entrariam" to drop sharply from 415 (Task-1-era numbers) since the BANK accounts' 219 previously-false-positive rows should now mostly resolve to cross-source dedup skips.

- [ ] **Step 4: Run the full test suite one last time**

```bash
mix test 2>&1 | tail -10
```

Expected: only the 3 known pre-existing `installment_live_test.exs` failures.

- [ ] **Step 5: Report to the user**

Summarize: what changed, the new dry-run totals, and that the `/pluggy` screen's real "Importar do Pluggy" / "Sincronizar" actions are now safe to use against the existing historical data without creating cross-source duplicates.
