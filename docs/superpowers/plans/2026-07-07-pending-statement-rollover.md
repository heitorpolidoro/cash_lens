# Pending Statement Rollover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mark credit-card statements without a Vencimento as `:pending`, and when the next boleto is imported, absorb the pending into it ("incorporada em [Mmm/YY]") and propagate the payment link.

**Architecture:** A nullable `absorbed_by_statement_id` FK on `credit_card_statements` records absorption. A pure-ish `CreditCards.absorb_pending/1` finds eligible earlier pending statements for a boleto and, if `boleto.total_a_pagar − |boleto line-items| == Σ pending.total_a_pagar` exactly, stamps them absorbed. `link_payment`/`unlink_payment` are extended to also (un)parent absorbed statements' transactions. Import triggers absorption on boleto creation; a mix task reconciles existing data.

**Tech Stack:** Elixir 1.18, Ecto/Postgres, Phoenix LiveView, ExUnit. Money is `Decimal`.

## Global Constraints

- A statement is a **boleto** when `due_date` is not nil; **pending** (non-boleto) when `due_date` is nil.
- Absorption formula (EXACT, `Decimal.equal?`): `boleto.total_a_pagar − Decimal.abs(sum(boleto line items)) == Σ eligible_pending.total_a_pagar`.
- Uses each pending's `total_a_pagar` (the amount that rolls forward), NOT the sum of its line items.
- **Eligible pending** for boleto B: `account_id == B.account_id`, `due_date` nil, `absorbed_by_statement_id` nil, `competencia` not nil, `competencia < B.competencia` (a pending only rolls forward). All-or-nothing over this whole set; no subset search.
- Money compared with `Decimal.equal?/2`, never `==`.
- Status priority: `:absorbed` > `:pending` > `:open`/`:linked`/`:divergent`.

---

### Task 1: Migration + schema field

**Files:**
- Create: `priv/repo/migrations/20260707120000_add_absorbed_by_to_statements.exs`
- Modify: `lib/cash_lens/credit_cards/statement.ex`

**Interfaces:**
- Produces: `credit_card_statements.absorbed_by_statement_id :binary_id` (nullable FK → `credit_card_statements`, `on_delete: :nilify_all`); `Statement` schema field `:absorbed_by_statement_id` + `belongs_to :absorbed_by`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule CashLens.Repo.Migrations.AddAbsorbedByToStatements do
  use Ecto.Migration

  def change do
    alter table(:credit_card_statements) do
      add :absorbed_by_statement_id,
          references(:credit_card_statements, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:credit_card_statements, [:absorbed_by_statement_id])
  end
end
```

- [ ] **Step 2: Add the field + association to the schema**

In `lib/cash_lens/credit_cards/statement.ex`, add to the `schema` block after `belongs_to :payment_transaction, ...`:

```elixir
    belongs_to :absorbed_by, __MODULE__, foreign_key: :absorbed_by_statement_id
```

And add `:absorbed_by_statement_id` to the `cast(...)` list in `changeset/2`, plus:

```elixir
    |> foreign_key_constraint(:absorbed_by_statement_id)
```

- [ ] **Step 3: Run the migration**

Run: `export $(cat .env | xargs) && mix ecto.migrate`
Expected: adds the column + index cleanly.

- [ ] **Step 4: Commit**

```bash
mix format
git add priv/repo/migrations/20260707120000_add_absorbed_by_to_statements.exs lib/cash_lens/credit_cards/statement.ex
git commit -m "feat(credit-card): add absorbed_by_statement_id to statements"
```

---

### Task 2: statement_status — :pending and :absorbed

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex` (`statement_status/2`)
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `Statement` (now with `absorbed_by_statement_id`, `due_date`).
- Produces: `statement_status(statement, line_total)` returns `:absorbed` when `absorbed_by_statement_id` set; `:pending` when `due_date` nil and no payment and not absorbed; else the existing `:open`/`:linked`/`:divergent`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "statement_status pending/absorbed" do
  test ":absorbed when absorbed_by is set (highest priority)" do
    s = %CashLens.CreditCards.Statement{absorbed_by_statement_id: Ecto.UUID.generate(), due_date: nil}
    assert CashLens.CreditCards.statement_status(s, Decimal.new("0")) == :absorbed
  end

  test ":pending when no Vencimento, no payment, not absorbed" do
    s = %CashLens.CreditCards.Statement{due_date: nil, payment_transaction_id: nil, absorbed_by_statement_id: nil}
    assert CashLens.CreditCards.statement_status(s, Decimal.new("0")) == :pending
  end

  test ":open still applies to an unpaid boleto (has Vencimento)" do
    s = %CashLens.CreditCards.Statement{due_date: ~D[2026-03-10], payment_transaction_id: nil, absorbed_by_statement_id: nil}
    assert CashLens.CreditCards.statement_status(s, Decimal.new("0")) == :open
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — a pending statement currently returns `:open`.

- [ ] **Step 3: Implement — add clauses BEFORE the existing ones**

In `lib/cash_lens/credit_cards.ex`, replace the current head:

```elixir
  def statement_status(%Statement{payment_transaction_id: nil}, _line_total), do: :open
```

with the ordered clauses (absorbed → pending → open → linked/divergent):

```elixir
  def statement_status(%Statement{absorbed_by_statement_id: id}, _line_total)
      when not is_nil(id),
      do: :absorbed

  def statement_status(%Statement{due_date: nil, payment_transaction_id: nil}, _line_total),
    do: :pending

  def statement_status(%Statement{payment_transaction_id: nil}, _line_total), do: :open
```

(The existing final clause computing `:linked`/`:divergent` stays as-is.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): :pending and :absorbed statement statuses"
```

---

### Task 3: absorb_pending/1 — eligibility + formula

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `Statement`, `statement_transactions/1`, `Repo`.
- Produces: `CreditCards.absorb_pending(boleto :: Statement.t()) :: [Statement.t()]` — for a boleto (due_date + total present), finds eligible earlier pending; if the exact formula holds over their whole set, stamps each `absorbed_by_statement_id = boleto.id` and returns them; otherwise returns `[]`. Non-boletos (due_date nil) or boletos without a total return `[]`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "absorb_pending/1" do
  setup do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    %{card: card}
  end

  test "absorbs an earlier pending when total - |items| equals its total", %{card: card} do
    # Pending Feb: total_a_pagar 3.40 (its line items are irrelevant to the formula)
    pending =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card, due_date: nil, competencia: ~D[2026-01-01], total_a_pagar: Decimal.new("3.40")
      })

    # Boleto March: total 56.53, line items summing to -53.13 -> 56.53 - 53.13 = 3.40
    boleto =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card, due_date: ~D[2026-03-10], competencia: ~D[2026-03-01], total_a_pagar: Decimal.new("56.53")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id, amount: Decimal.new("-53.13"), import_batch_id: boleto.id, date: ~D[2026-02-20]
    })

    assert [absorbed] = CashLens.CreditCards.absorb_pending(boleto)
    assert absorbed.id == pending.id
    assert CashLens.CreditCards.get_statement!(pending.id).absorbed_by_statement_id == boleto.id
  end

  test "does not absorb when the sum is off by a cent", %{card: card} do
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card, due_date: nil, competencia: ~D[2026-01-01], total_a_pagar: Decimal.new("3.41")
    })

    boleto =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card, due_date: ~D[2026-03-10], competencia: ~D[2026-03-01], total_a_pagar: Decimal.new("56.53")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id, amount: Decimal.new("-53.13"), import_batch_id: boleto.id
    })

    assert CashLens.CreditCards.absorb_pending(boleto) == []
  end

  test "ignores pending that are not earlier than the boleto", %{card: card} do
    # competencia == boleto's (not strictly earlier) -> not eligible
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card, due_date: nil, competencia: ~D[2026-03-01], total_a_pagar: Decimal.new("0.00")
    })

    boleto =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card, due_date: ~D[2026-03-10], competencia: ~D[2026-03-01], total_a_pagar: Decimal.new("53.13")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id, amount: Decimal.new("-53.13"), import_batch_id: boleto.id
    })

    assert CashLens.CreditCards.absorb_pending(boleto) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `absorb_pending/1` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  @doc """
  Absorbs a boleto's eligible earlier pending statements when the accounts
  reconcile exactly: `boleto.total_a_pagar - |sum(boleto items)| == Σ
  eligible_pending.total_a_pagar`. Stamps each absorbed statement with
  `absorbed_by_statement_id = boleto.id` and returns them. Returns [] for
  non-boletos, boletos without a total, or when the sum does not match.
  """
  def absorb_pending(%Statement{due_date: nil}), do: []
  def absorb_pending(%Statement{total_a_pagar: nil}), do: []

  def absorb_pending(%Statement{} = boleto) do
    pending = eligible_pending(boleto)

    if pending == [] do
      []
    else
      line_total = boleto.id |> statement_transactions() |> sum_amounts()
      rolled = Decimal.sub(boleto.total_a_pagar, Decimal.abs(line_total))
      sum_pending = Enum.reduce(pending, Decimal.new(0), &Decimal.add(&2, &1.total_a_pagar || Decimal.new(0)))

      if Decimal.equal?(rolled, sum_pending) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        ids = Enum.map(pending, & &1.id)

        from(s in Statement, where: s.id in ^ids)
        |> Repo.update_all(set: [absorbed_by_statement_id: boleto.id, updated_at: now])

        pending
      else
        []
      end
    end
  end

  defp eligible_pending(%Statement{} = boleto) do
    from(s in Statement,
      where: s.account_id == ^boleto.account_id,
      where: is_nil(s.due_date),
      where: is_nil(s.absorbed_by_statement_id),
      where: not is_nil(s.competencia),
      where: s.competencia < ^boleto.competencia
    )
    |> Repo.all()
  end

  defp sum_amounts(transactions) do
    Enum.reduce(transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): absorb_pending exact-sum rollover"
```

---

### Task 4: link_payment/unlink_payment cover absorbed statements

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex` (`link_payment/2`, `unlink_payment/1`)
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `Statement`, `Transaction`, `absorbed_by_statement_id`.
- Produces: `link_payment(boleto, payment_id)` now parents transactions whose `import_batch_id` is the boleto's id OR belongs to any statement absorbed by the boleto; `unlink_payment(boleto)` clears both. Return shape unchanged (`{:ok, Statement}`).

- [ ] **Step 1: Write the failing test**

```elixir
test "link_payment also parents transactions of absorbed statements" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  bank = CashLens.AccountsFixtures.account_fixture(%{})

  boleto =
    CashLens.CreditCardsFixtures.statement_fixture(%{account: card, total_a_pagar: Decimal.new("56.53")})

  absorbed =
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card, due_date: nil, total_a_pagar: Decimal.new("3.40"),
      absorbed_by_statement_id: boleto.id
    })

  boleto_tx =
    CashLens.TransactionsFixtures.transaction_fixture(%{account_id: card.id, import_batch_id: boleto.id})

  absorbed_tx =
    CashLens.TransactionsFixtures.transaction_fixture(%{account_id: card.id, import_batch_id: absorbed.id})

  payment = CashLens.TransactionsFixtures.transaction_fixture(%{account_id: bank.id})

  {:ok, _} = CashLens.CreditCards.link_payment(boleto, payment.id)

  reload = fn id -> CashLens.Repo.get!(CashLens.Transactions.Transaction, id).parent_transaction_id end
  assert reload.(boleto_tx.id) == payment.id
  assert reload.(absorbed_tx.id) == payment.id

  {:ok, _} = CashLens.CreditCards.unlink_payment(boleto)
  assert reload.(boleto_tx.id) == nil
  assert reload.(absorbed_tx.id) == nil
end
```

(`statement_fixture/1` must accept `absorbed_by_statement_id`; it casts through `Statement.changeset/2`, which now includes that field from Task 1.)

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — absorbed_tx not parented.

- [ ] **Step 3: Implement — widen the children query in both functions**

In `lib/cash_lens/credit_cards.ex`, add a helper and use it in both `link_payment/2` and `unlink_payment/1` in place of the inline `from(t in Transaction, where: t.import_batch_id == ^statement.id)`:

```elixir
  # Statement ids whose transactions a boleto's payment covers: the boleto
  # itself plus every statement absorbed into it.
  defp covered_statement_ids(%Statement{} = boleto) do
    absorbed =
      from(s in Statement, where: s.absorbed_by_statement_id == ^boleto.id, select: s.id)
      |> Repo.all()

    [boleto.id | absorbed]
  end
```

Then in `link_payment/2`, change the `Multi.update_all(:children, ...)` query to:

```elixir
      from(t in Transaction, where: t.import_batch_id in ^covered_statement_ids(statement)),
```

and identically in `unlink_payment/1`. (Everything else in both functions stays the same.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS (existing link/unlink tests still pass — a boleto with no absorbed statements yields just `[boleto.id]`).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): payment link covers absorbed statements' transactions"
```

---

### Task 5: Trigger absorption on boleto import

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex` (`process_entries/4`)
- Test: `test/cash_lens/parsers/ingestor_test.exs`

**Interfaces:**
- Consumes: `CreditCards.absorb_pending/1`, `CreditCards.get_statement!/1`, `Matcher.auto_link/2`.
- Produces: when a boleto statement is created during import, `absorb_pending/1` runs before `auto_link/2`, so an eligible earlier pending is stamped absorbed and its transactions get covered by the boleto's payment link.

- [ ] **Step 1: Read the current trigger**

Read `lib/cash_lens/parsers/ingestor.ex` `process_entries/4`. It currently, when `statement_id` is set, does:

```elixir
    if statement_id do
      statement = CashLens.CreditCards.get_statement!(statement_id)
      line_total = Enum.reduce(inserted_transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))
      CashLens.CreditCards.Matcher.auto_link(statement, line_total)
    end
```

- [ ] **Step 2: Write the failing test**

```elixir
test "importing a boleto absorbs an earlier eligible pending statement" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, parser_type: "bb_csv"})

  # Seed a pending (non-boleto) statement + its stamped transaction directly.
  pending =
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card, due_date: nil, competencia: ~D[2026-01-01], total_a_pagar: Decimal.new("3.40")
    })

  CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: card.id, amount: Decimal.new("-3.40"), import_batch_id: pending.id, date: ~D[2026-01-15]
  })

  # Import a boleto whose meta gives due_date + total 56.53 and whose one line
  # item sums to -53.13, so 56.53 - 53.13 = 3.40 absorbs the pending.
  content = boleto_fixture_content()  # see note below
  {:ok, _} = import_boleto(card, content)  # adapt to the existing ingestor test harness

  reloaded = CashLens.CreditCards.get_statement!(pending.id)
  assert reloaded.absorbed_by_statement_id != nil
end
```

Adapt `boleto_fixture_content/0` + `import_boleto/2` to the existing `ingestor_test.exs` harness (it stubs the parser/converter and drives `Ingestor.import_file`/`process_imported_content`). The boleto must parse to one `-53.13` transaction and its `statement_meta` must yield `due_date: ~D[2026-03-10]`, `total_a_pagar: 56.53`, `competencia: ~D[2026-03-01]`. If the harness makes seeding a precise boleto awkward, instead unit-test the ordering by asserting `process_entries` calls `absorb_pending` before `auto_link` via the observable outcome (absorbed set) — do NOT weaken to a stub-only assertion.

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: FAIL — pending not absorbed on import.

- [ ] **Step 4: Implement — call absorb_pending before auto_link**

In `process_entries/4`, change the `if statement_id` block to:

```elixir
    if statement_id do
      statement = CashLens.CreditCards.get_statement!(statement_id)
      CashLens.CreditCards.absorb_pending(statement)
      line_total = Enum.reduce(inserted_transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))
      CashLens.CreditCards.Matcher.auto_link(statement, line_total)
    end
```

- [ ] **Step 5: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ingestor_test.exs && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens/parsers/ingestor.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "feat(ingestor): absorb pending statements on boleto import"
```

---

### Task 6: Retroactive reconciliation mix task

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex` (add `reconcile_pending/0`)
- Create: `lib/mix/tasks/cash_lens.reconcile_pending_statements.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `absorb_pending/1`, `link_payment/2`, `Statement`.
- Produces: `CreditCards.reconcile_pending() :: non_neg_integer()` — iterates every boleto (due_date not nil) across all credit-card accounts in chronological order (`competencia` asc, `inserted_at` asc), runs `absorb_pending/1`; for each boleto that already has a `payment_transaction_id`, re-runs `link_payment/2` so newly-absorbed transactions get parented. Returns the count of statements newly absorbed. Idempotent. Mix task `cash_lens.reconcile_pending_statements` calls it and prints the count.

- [ ] **Step 1: Write the failing test**

```elixir
test "reconcile_pending absorbs existing pending and propagates an existing payment" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  bank = CashLens.AccountsFixtures.account_fixture(%{})

  pending =
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card, due_date: nil, competencia: ~D[2026-01-01], total_a_pagar: Decimal.new("3.40")
    })

  pending_tx =
    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id, amount: Decimal.new("-3.40"), import_batch_id: pending.id
    })

  payment = CashLens.TransactionsFixtures.transaction_fixture(%{account_id: bank.id})

  boleto =
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card, due_date: ~D[2026-03-10], competencia: ~D[2026-03-01],
      total_a_pagar: Decimal.new("56.53"), payment_transaction_id: payment.id
    })

  CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: card.id, amount: Decimal.new("-53.13"), import_batch_id: boleto.id
  })

  assert CashLens.CreditCards.reconcile_pending() == 1
  assert CashLens.CreditCards.get_statement!(pending.id).absorbed_by_statement_id == boleto.id
  # payment propagated to the absorbed statement's transaction
  assert CashLens.Repo.get!(CashLens.Transactions.Transaction, pending_tx.id).parent_transaction_id == payment.id

  # idempotent
  assert CashLens.CreditCards.reconcile_pending() == 0
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `reconcile_pending/0` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  @doc """
  Applies `absorb_pending/1` to every existing boleto in chronological order,
  propagating an already-linked payment to newly-absorbed transactions.
  Returns the number of statements newly absorbed. Idempotent.
  """
  def reconcile_pending do
    boletos =
      from(s in Statement,
        where: not is_nil(s.due_date),
        order_by: [asc: s.competencia, asc: s.inserted_at]
      )
      |> Repo.all()

    Enum.reduce(boletos, 0, fn boleto, count ->
      case absorb_pending(boleto) do
        [] ->
          count

        absorbed ->
          if boleto.payment_transaction_id do
            link_payment(boleto, boleto.payment_transaction_id)
          end

          count + length(absorbed)
      end
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the mix task**

```elixir
defmodule Mix.Tasks.CashLens.ReconcilePendingStatements do
  use Mix.Task
  @shortdoc "Absorbs existing pending statements into their boletos"

  @moduledoc """
      mix cash_lens.reconcile_pending_statements

  One-time reconciliation over already-imported data: absorbs each non-boleto
  (no Vencimento) statement into the next boleto whose accounts reconcile
  exactly, propagating an already-linked payment. Idempotent.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    n = CashLens.CreditCards.reconcile_pending()
    Mix.shell().info("Reconciled: #{n} statement(s) absorbed.")
  end
end
```

- [ ] **Step 6: Verify compile + commit**

Run: `export $(cat .env | xargs) && mix compile --warnings-as-errors`
Expected: clean.

```bash
mix format
git add lib/cash_lens/credit_cards.ex lib/mix/tasks/cash_lens.reconcile_pending_statements.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(mix): reconcile_pending_statements retroactive absorption"
```

---

### Task 7: LiveView — pending / absorbed badges

**Files:**
- Modify: `lib/cash_lens_web/live/credit_card_statement_live/index.ex`
- Test: `test/cash_lens_web/live/credit_card_statement_live_test.exs`

**Interfaces:**
- Consumes: `list_statements/0` rows (whose `status` is now possibly `:pending`/`:absorbed`), `get_statement_detail/1`.
- Produces: overview shows `⏳ Pendente` (amber) for `:pending` with the tip text, and a muted "Incorporada em [Mmm/YY]" for `:absorbed`; detail shows the tip / the absorbing link.

- [ ] **Step 1: Read the current status_badge**

Read `lib/cash_lens_web/live/credit_card_statement_live/index.ex` `status_badge/1` (maps `:linked`→`badge-success`✅, `:open`→`badge-warning`⚠, `:divergent`→`badge-error`❗). Note the surrounding table markup and how `get_statement_detail/1` exposes the absorbing statement (it does not yet — see Step 3).

- [ ] **Step 2: Write the failing test**

```elixir
test "overview shows a Pendente badge for a pending statement", %{conn: conn} do
  account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, name: "Amazon"})
  CashLens.CreditCardsFixtures.statement_fixture(%{account: account, due_date: nil, total_a_pagar: Decimal.new("3.40")})

  {:ok, _view, html} = live(conn, ~p"/statements")
  assert html =~ "Pendente"
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/credit_card_statement_live_test.exs`
Expected: FAIL — no "Pendente" badge.

- [ ] **Step 4: Implement**

Add `:pending` and `:absorbed` cases to `status_badge/1`:

```elixir
  defp status_badge(:absorbed), do: {"badge-ghost", "Incorporada"}
  defp status_badge(:pending), do: {"badge-warning", "⏳ Pendente"}
```

(Keep the existing `:linked`/`:open`/`:divergent` clauses. Match the existing tuple/return shape the function already uses — read it first and mirror it exactly, whether it returns a tuple, a class string, or renders inline.)

For the overview row, when `s.status == :pending`, render the tip text near the badge (small, muted):

```heex
<span :if={s.status == :pending} class="text-[10px] opacity-50 ml-1">possível cobrança na próxima fatura</span>
```

For `:absorbed`, show `Incorporada em {format_competencia(...)}` — the competência of the absorbing boleto. Extend `CreditCards.list_statements/0`'s row map (in `credit_cards.ex`) to include `absorbed_into: <absorbing statement's competencia or nil>` by preloading `:absorbed_by` on the statements query and reading `s.absorbed_by && s.absorbed_by.competencia`. Then render it in the label. Keep the change minimal and covered by the existing list_statements test (add an assertion there if you extend the row map).

- [ ] **Step 5: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/credit_card_statement_live_test.exs && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens_web/live/credit_card_statement_live/index.ex lib/cash_lens/credit_cards.ex test/cash_lens_web/live/credit_card_statement_live_test.exs
git commit -m "feat(web): pending and absorbed statement badges"
```

---

## Post-implementation (operational)

After merge: run `mix cash_lens.reconcile_pending_statements` against the local DB to absorb the existing pending (Amazon 3,40 → March boleto; the empty 0,00/0,33 have no eligible following boleto and stay `:pending`). Then confirm on `/statements`.

## Self-Review

**Spec coverage:**
- Data model `absorbed_by_statement_id` → Task 1.
- Status `:pending`/`:absorbed` with priority → Task 2.
- Absorption formula + eligibility (`competencia < B.competencia`, all-or-nothing, exact) → Task 3.
- Payment covers absorbed transactions (link/unlink) → Task 4.
- Import trigger (absorb before auto_link) → Task 5.
- Retroactive reconciliation + payment propagation + idempotent + mix task → Task 6.
- UI badges + tip + "Incorporada em [Mmm/YY]" → Task 7.

**Placeholder scan:** Task 5's test defers the boleto-content seeding to the existing ingestor harness with an explicit "do not weaken to stub-only" instruction; Task 7 mirrors the existing `status_badge/1` shape after reading it. No silent TODOs.

**Type consistency:** `absorb_pending/1` ([Statement]), `reconcile_pending/0` (integer), `link_payment/2`/`unlink_payment/1` ({:ok, Statement}), `statement_status/2` (atom), `covered_statement_ids/1` ([id]) are used consistently across tasks. `absorbed_by_statement_id` is the field name everywhere. The formula uses `total_a_pagar` (pending) and `Decimal.abs(sum items)` (boleto) as defined in Global Constraints.
