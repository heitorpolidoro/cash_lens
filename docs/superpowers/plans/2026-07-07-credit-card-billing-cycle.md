# Credit-Card Billing Cycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure each credit-card account's billing cycle (closing day + due day) and derive statement competência from it, so non-boleto statements land in the correct month; flag files whose Vencimento diverges from the configured cycle.

**Architecture:** Two nullable integer fields on `accounts` hold the cycle. `CreditCards.competencia_for/3` computes competência from the cycle for non-boletos (falling back to the current transaction-month heuristic when no cycle is set). `estimate_cycle/1` seeds the fields from imported boletos. Import wires `competencia_for/3` in; a mix task recomputes existing statements; the directory importer collects per-account cycle divergences; the accounts form and batch-import UI surface them.

**Tech Stack:** Elixir 1.18, Ecto/Postgres, Phoenix LiveView, ExUnit.

## Global Constraints

- Cycle fields apply only to `is_credit_card` accounts; both nullable, validated `1..31`.
- competência = `Date.beginning_of_month(due_date)`. Boleto: due_date from the file. Non-boleto with cycle: due_date computed from the cycle. Non-boleto without cycle: current `competencia_from/2` fallback (no regression).
- Cycle derivation for a non-boleto uses the statement's LATEST transaction date `D`:
  1. closing = first `closing_day` strictly after `D` (roll to next month if `D.day >= closing_day`);
  2. due = `due_day` in closing's month if `due_day > closing_day`, else in the month after closing;
  3. competência = `beginning_of_month(due)`.
  Day-of-month values are clamped to the target month's length.
- Only `due_day` is validated against imported files (Vencimento is explicit; closing isn't in the file).
- Money/day comparisons: plain integers for days; `Date` functions for dates.

---

### Task 1: Migration + Account cycle fields

**Files:**
- Create: `priv/repo/migrations/20260707130000_add_billing_cycle_to_accounts.exs`
- Modify: `lib/cash_lens/accounts/account.ex`
- Test: `test/cash_lens/accounts_test.exs` (add cases; create if absent)

**Interfaces:**
- Produces: `accounts.closing_day :integer` and `accounts.due_day :integer` (both nullable); `Account` schema fields + cast + `validate_inclusion(1..31)`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule CashLens.Repo.Migrations.AddBillingCycleToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :closing_day, :integer
      add :due_day, :integer
    end
  end
end
```

- [ ] **Step 2: Write the failing test**

```elixir
test "changeset accepts closing_day/due_day and validates range" do
  valid = CashLens.Accounts.Account.changeset(%CashLens.Accounts.Account{}, %{
    name: "C", bank: "B", balance: 0, accepts_import: true, is_closed: false,
    is_credit_card: true, closing_day: 3, due_day: 10
  })
  assert valid.valid?

  invalid = CashLens.Accounts.Account.changeset(%CashLens.Accounts.Account{}, %{
    name: "C", bank: "B", balance: 0, accepts_import: true, is_closed: false,
    closing_day: 0, due_day: 40
  })
  refute invalid.valid?
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/accounts_test.exs`
Expected: FAIL — fields not cast.

- [ ] **Step 4: Implement**

Add `field :closing_day, :integer` and `field :due_day, :integer` to the `schema "accounts"` block. Add `:closing_day, :due_day` to the `cast/3` list. After `validate_required`, add:

```elixir
    |> validate_inclusion(:closing_day, 1..31)
    |> validate_inclusion(:due_day, 1..31)
```

(`validate_inclusion` passes when the field is nil, so nullable is preserved.)

- [ ] **Step 5: Migrate + run tests**

Run: `export $(cat .env | xargs) && mix ecto.migrate && mix test test/cash_lens/accounts_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add priv/repo/migrations/20260707130000_add_billing_cycle_to_accounts.exs lib/cash_lens/accounts/account.ex test/cash_lens/accounts_test.exs
git commit -m "feat(accounts): add closing_day/due_day billing-cycle fields"
```

---

### Task 2: competencia_for/3 — cycle-derived competência

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: existing `competencia_from/2`.
- Produces: `CreditCards.competencia_for(account, meta, transactions) :: Date.t() | nil` where `meta` is the `%{due_date, total_a_pagar, competencia}` map and `account` is an `%Account{}` (or any map with `:closing_day`/`:due_day`). Boleto (`meta.competencia` present) → that. Non-boleto + cycle set → cycle-derived. Non-boleto + no cycle → `competencia_from(meta.competencia, transactions)`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "competencia_for/3" do
  @cycle %{closing_day: 3, due_day: 10}

  test "boleto uses the parsed competência (due month)" do
    meta = %{due_date: ~D[2026-03-10], total_a_pagar: nil, competencia: ~D[2026-03-01]}
    assert CashLens.CreditCards.competencia_for(@cycle, meta, []) == ~D[2026-03-01]
  end

  test "non-boleto with cycle: latest tx 27/01, closing 3, due 10 -> Fev/26" do
    meta = %{due_date: nil, total_a_pagar: nil, competencia: nil}
    txns = [%{date: ~D[2026-01-12]}, %{date: ~D[2026-01-27]}]
    assert CashLens.CreditCards.competencia_for(@cycle, meta, txns) == ~D[2026-02-01]
  end

  test "non-boleto, tx before closing_day stays in the same closing month" do
    meta = %{due_date: nil, competencia: nil}
    # closing 25, due 10 (due <= closing -> due next month). tx 20/06 -> closing 25/06 -> due 10/07
    cycle = %{closing_day: 25, due_day: 10}
    assert CashLens.CreditCards.competencia_for(cycle, meta, [%{date: ~D[2026-06-20]}]) == ~D[2026-07-01]
  end

  test "non-boleto without cycle falls back to transaction month" do
    meta = %{due_date: nil, competencia: nil}
    cycle = %{closing_day: nil, due_day: nil}
    assert CashLens.CreditCards.competencia_for(cycle, meta, [%{date: ~D[2026-01-27]}]) == ~D[2026-01-01]
  end

  test "non-boleto with cycle but no transactions -> nil" do
    assert CashLens.CreditCards.competencia_for(@cycle, %{due_date: nil, competencia: nil}, []) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `competencia_for/3` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  @doc """
  Competência for a statement, preferring the cycle over the transaction-date
  heuristic. Boleto (meta already has a competência from its Vencimento) → that.
  Non-boleto with a configured cycle → derived from closing_day/due_day and the
  latest transaction. Non-boleto without a cycle → `competencia_from/2`.
  """
  def competencia_for(_account, %{competencia: %Date{} = competencia}, _transactions),
    do: competencia

  def competencia_for(%{closing_day: c, due_day: d}, _meta, transactions)
      when is_integer(c) and is_integer(d) do
    case latest_transaction_date(transactions) do
      nil -> nil
      latest -> latest |> first_closing_after(c) |> due_from_closing(c, d) |> Date.beginning_of_month()
    end
  end

  def competencia_for(_account, meta, transactions),
    do: competencia_from(meta.competencia, transactions)

  defp latest_transaction_date(transactions) do
    transactions |> Enum.map(&Map.get(&1, :date)) |> Enum.reject(&is_nil/1) |> Enum.max(Date, fn -> nil end)
  end

  # First `closing_day` strictly after `date` (rolls to next month if the
  # closing day of `date`'s month has already passed).
  defp first_closing_after(%Date{} = date, closing_day) do
    this = clamp_day(date.year, date.month, closing_day)

    if Date.compare(this, date) == :gt do
      this
    else
      {y, m} = next_month(date.year, date.month)
      clamp_day(y, m, closing_day)
    end
  end

  # Due date after a closing: same month when due_day is later than closing_day,
  # otherwise the following month.
  defp due_from_closing(%Date{} = closing, closing_day, due_day) do
    if due_day > closing_day do
      clamp_day(closing.year, closing.month, due_day)
    else
      {y, m} = next_month(closing.year, closing.month)
      clamp_day(y, m, due_day)
    end
  end

  defp clamp_day(year, month, day) do
    max_day = Date.days_in_month(Date.new!(year, month, 1))
    Date.new!(year, month, min(day, max_day))
  end

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): competencia_for derives competência from billing cycle"
```

---

### Task 3: estimate_cycle/1

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `Statement`, `Repo`.
- Produces: `CreditCards.estimate_cycle(account) :: %{closing_day: 1..31 | nil, due_day: 1..31 | nil}` — `due_day` = the most common day among the account's boletos' `due_date`s; `closing_day` = `due_day - 7` normalized into `1..31` (wrapping when negative). Nils when the account has no boletos.

- [ ] **Step 1: Write the failing test**

```elixir
describe "estimate_cycle/1" do
  test "estimates due_day as the modal boleto due day and closing 7 days earlier" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    statement_fixture(%{account: card, due_date: ~D[2026-01-10]})
    statement_fixture(%{account: card, due_date: ~D[2026-02-10]})
    statement_fixture(%{account: card, due_date: ~D[2026-03-15]})

    assert CashLens.CreditCards.estimate_cycle(card) == %{closing_day: 3, due_day: 10}
  end

  test "wraps closing_day when due_day <= 7" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    statement_fixture(%{account: card, due_date: ~D[2026-01-05]})
    assert CashLens.CreditCards.estimate_cycle(card) == %{closing_day: 28, due_day: 5}
  end

  test "nils when the account has no boletos" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    assert CashLens.CreditCards.estimate_cycle(card) == %{closing_day: nil, due_day: nil}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `estimate_cycle/1` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  @closing_offset 7

  @doc """
  Best-effort billing-cycle estimate from the account's imported boletos:
  `due_day` = most common Vencimento day, `closing_day` = 7 days earlier
  (wrapped into 1..31). Nils when there are no boletos. The user confirms.
  """
  def estimate_cycle(account) do
    days =
      from(s in Statement,
        where: s.account_id == ^account.id and not is_nil(s.due_date),
        select: s.due_date
      )
      |> Repo.all()
      |> Enum.map(& &1.day)

    case days do
      [] ->
        %{closing_day: nil, due_day: nil}

      days ->
        due_day = mode(days)
        closing = due_day - @closing_offset
        closing_day = if closing < 1, do: closing + 30, else: closing
        %{closing_day: closing_day, due_day: due_day}
    end
  end

  defp mode(list) do
    list
    |> Enum.frequencies()
    |> Enum.max_by(fn {_value, count} -> count end)
    |> elem(0)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): estimate_cycle from imported boletos"
```

---

### Task 4: Use competencia_for on import

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex` (`maybe_create_statement/4`)
- Test: `test/cash_lens/parsers/ingestor_test.exs`

**Interfaces:**
- Consumes: `CreditCards.competencia_for/3`.
- Produces: importing a non-boleto file into a credit-card account WITH a cycle stamps the cycle-derived competência instead of the transaction-month heuristic.

- [ ] **Step 1: Write the failing test**

```elixir
test "non-boleto import uses the account's cycle for competência" do
  account =
    CashLens.AccountsFixtures.account_fixture(%{
      is_credit_card: true, parser_type: "ourocard_txt", closing_day: 3, due_day: 10
    })

  # A .txt with NO Vencimento line, one transaction dated 27/01 -> cycle -> Fev/26.
  content = "27.01.2026COMPRA          SAO PAULO   BR              50,00        0,00\n"
  path = Path.join(System.tmp_dir!(), "nb_#{System.unique_integer([:positive])}.txt")
  File.write!(path, content)

  {:ok, %{imported: 1}} = CashLens.Parsers.Ingestor.import_file(account, path)

  [s] = CashLens.Repo.all(from s in CashLens.CreditCards.Statement, where: s.account_id == ^account.id)
  assert s.due_date == nil
  assert s.competencia == ~D[2026-02-01]
end
```

(Add `import Ecto.Query` to the test file if not present.)

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: FAIL — competência is `~D[2026-01-01]` (transaction month), not Fev.

- [ ] **Step 3: Implement**

In `lib/cash_lens/parsers/ingestor.ex`, `maybe_create_statement/4`, change the `competencia:` line from:

```elixir
        competencia: CashLens.CreditCards.competencia_from(meta.competencia, transactions),
```

to:

```elixir
        competencia: CashLens.CreditCards.competencia_for(account, meta, transactions),
```

- [ ] **Step 4: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ingestor_test.exs && mix test`
Expected: PASS (accounts without a cycle still use the fallback → existing tests green).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/parsers/ingestor.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "feat(ingestor): derive competência from the account billing cycle"
```

---

### Task 5: recompute_competencia mix task

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex` (add `recompute_competencia/0`)
- Create: `lib/mix/tasks/cash_lens.recompute_competencia.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `competencia_for/3`, `statement_transactions/1`, `Statement`, `Accounts`.
- Produces: `CreditCards.recompute_competencia() :: non_neg_integer()` — for every statement on a credit-card account that has a cycle, recompute competência via `competencia_for(account, %{due_date: s.due_date, competencia: (due-month or nil)}, statement_transactions)` and update it when changed; returns the count updated. Idempotent. Mix task `cash_lens.recompute_competencia` calls it and prints the count.

- [ ] **Step 1: Write the failing test**

```elixir
test "recompute_competencia fixes a non-boleto's competência from the cycle" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10})

  s =
    statement_fixture(%{
      account: card, due_date: nil, competencia: ~D[2026-01-01], total_a_pagar: Decimal.new("50.00")
    })

  CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: card.id, amount: Decimal.new("-50.00"), import_batch_id: s.id, date: ~D[2026-01-27]
  })

  assert CashLens.CreditCards.recompute_competencia() == 1
  assert CashLens.CreditCards.get_statement!(s.id).competencia == ~D[2026-02-01]
  # idempotent
  assert CashLens.CreditCards.recompute_competencia() == 0
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `recompute_competencia/0` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  @doc """
  Recomputes competência for statements on credit-card accounts that have a
  cycle, via `competencia_for/3`. Updates only when it changes; returns the
  count updated. Idempotent. Boletos (with due_date) resolve to their due month
  either way.
  """
  def recompute_competencia do
    accounts =
      from(a in CashLens.Accounts.Account,
        where: a.is_credit_card == true and not is_nil(a.closing_day) and not is_nil(a.due_day)
      )
      |> Repo.all()

    Enum.reduce(accounts, 0, fn account, count ->
      statements = from(s in Statement, where: s.account_id == ^account.id) |> Repo.all()

      Enum.reduce(statements, count, fn s, acc ->
        meta = %{
          due_date: s.due_date,
          competencia: s.due_date && Date.beginning_of_month(s.due_date)
        }

        new_comp = competencia_for(account, meta, statement_transactions(s.id))

        if new_comp && new_comp != s.competencia do
          {:ok, _} = update_statement_competencia(s, new_comp)
          acc + 1
        else
          acc
        end
      end)
    end)
  end

  defp update_statement_competencia(%Statement{} = s, competencia) do
    s |> Statement.changeset(%{competencia: competencia}) |> Repo.update()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the mix task**

```elixir
defmodule Mix.Tasks.CashLens.RecomputeCompetencia do
  use Mix.Task
  @shortdoc "Recomputes statement competência from each card's billing cycle"

  @moduledoc """
      mix cash_lens.recompute_competencia

  Recomputes competência for statements on credit-card accounts that have a
  configured cycle. Idempotent. Run after setting/confirming cycles; then
  re-run `mix cash_lens.reconcile_pending_statements`.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    n = CashLens.CreditCards.recompute_competencia()
    Mix.shell().info("Recomputed competência for #{n} statement(s).")
  end
end
```

- [ ] **Step 6: Verify compile + commit**

Run: `export $(cat .env | xargs) && mix compile --warnings-as-errors`
Expected: clean.

```bash
mix format
git add lib/cash_lens/credit_cards.ex lib/mix/tasks/cash_lens.recompute_competencia.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(mix): recompute_competencia from billing cycle"
```

---

### Task 6: DirectoryImporter collects cycle divergences

**Files:**
- Modify: `lib/cash_lens/parsers/directory_importer.ex`
- Test: `test/cash_lens/parsers/directory_importer_test.exs` (add cases)

**Interfaces:**
- Consumes: the account's `due_day`, imported statements' `due_date`.
- Produces: `%DirectoryImporter.Result{}` gains a `cycle_warnings: []` field, each entry `%{account_id: binary_id, account_name: String.t(), file: String.t(), file_due_day: 1..31, configured_due_day: 1..31}` — one per imported boleto whose Vencimento day differs from the account's configured `due_day`. Empty when the account has no `due_day` or the days match. (`account_id` lets the UI target the account unambiguously.)

- [ ] **Step 1: Read the current run/result shape**

Read `lib/cash_lens/parsers/directory_importer.ex`: `Result` struct is `accounts: [], warnings: [], errors: []`. Find where per-account import finishes (around `do_import/7`) so you can compare the resulting statements' `due_date` against `account.due_day` and accumulate divergences into the result.

- [ ] **Step 2: Write the failing test**

```elixir
test "run collects a cycle_warning when a boleto's Vencimento day differs from the account's due_day" do
  # Set up an account with due_day 7, import a folder whose boleto has Vencimento day 16.
  # (Follow the existing directory_importer_test harness for folder/.account setup;
  # assert result.cycle_warnings has one entry with file_due_day 16, configured_due_day 7.)
  ...
end
```

Adapt to the existing `directory_importer_test.exs` harness (it builds a temp folder with `.account` files and calls `DirectoryImporter.run/2`). If that harness can't easily produce a boleto with a specific Vencimento, drive the divergence-collection helper you extract in Step 3 directly with seeded statements + an account, asserting the returned warning list — do NOT assert on a stub.

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/directory_importer_test.exs`
Expected: FAIL — `cycle_warnings` absent.

- [ ] **Step 4: Implement**

Add `cycle_warnings: []` to the `Result` defstruct. After importing an account's files, compare its statements' `due_date` days to `account.due_day` (skip when `due_day` is nil), building entries `%{account_id: account.id, account_name: account.name, file: s.source_file, file_due_day: s.due_date.day, configured_due_day: account.due_day}` for the mismatches, and append them to `result.cycle_warnings`. Factor the comparison into a small private helper `cycle_divergences(account, statements)` so the test can drive it directly.

- [ ] **Step 5: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/directory_importer_test.exs && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens/parsers/directory_importer.ex test/cash_lens/parsers/directory_importer_test.exs
git commit -m "feat(importer): collect billing-cycle divergences per import"
```

---

### Task 7: Accounts form — cycle fields + estimate

**Files:**
- Modify: `lib/cash_lens_web/live/account_live/form.ex`
- Test: `test/cash_lens_web/live/account_live_test.exs` (add cases; follow existing style)

**Interfaces:**
- Consumes: `CreditCards.estimate_cycle/1`; the `Account` changeset (now casting `closing_day`/`due_day`).
- Produces: the account form shows **Dia de fechamento** and **Dia de vencimento** number inputs when `is_credit_card`, and an "Estimar do histórico" button (`phx-click="estimate_cycle"`) that fills them from `estimate_cycle/1`.

- [ ] **Step 1: Read the form**

Read `lib/cash_lens_web/live/account_live/form.ex`: how it renders inputs (`<.input field={@form[:...]}>`), how it holds the changeset/form assign, and how existing `phx-click` events update the form. Mirror those patterns.

- [ ] **Step 2: Write the failing test**

```elixir
test "credit-card account form shows cycle fields and estimate button", %{conn: conn} do
  account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  {:ok, _view, html} = live(conn, ~p"/accounts/#{account}/edit")
  assert html =~ "Dia de fechamento"
  assert html =~ "Estimar do histórico"
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/account_live_test.exs`
Expected: FAIL — labels absent.

- [ ] **Step 4: Implement**

In the form template, inside a block gated on the account being a credit card (mirror how the form conditions on `is_credit_card` if it already does; otherwise gate on the form's `:is_credit_card` value), add:

```heex
<.input field={@form[:closing_day]} type="number" label="Dia de fechamento" min="1" max="31" />
<.input field={@form[:due_day]} type="number" label="Dia de vencimento" min="1" max="31" />
<button type="button" class="btn btn-xs btn-outline" phx-click="estimate_cycle">
  Estimar do histórico
</button>
```

Add the event handler (the form edits an existing account; use the account assign):

```elixir
  @impl true
  def handle_event("estimate_cycle", _params, socket) do
    est = CashLens.CreditCards.estimate_cycle(socket.assigns.account)

    changeset =
      socket.assigns.account
      |> Ecto.Changeset.change(closing_day: est.closing_day, due_day: est.due_day)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end
```

(Match the socket assigns the form actually uses — read them first; if it stores `:changeset` rather than `:form`, adapt. Fill in the estimated values without saving.)

- [ ] **Step 5: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/account_live_test.exs && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens_web/live/account_live/form.ex test/cash_lens_web/live/account_live_test.exs
git commit -m "feat(web): billing-cycle fields + estimate button on account form"
```

---

### Task 8: Batch-import divergence summary

**Files:**
- Modify: `lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex`
- Test: `test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs` (or the closest existing test for this component; create if absent)

**Interfaces:**
- Consumes: `DirectoryImporter.run/2`'s `result.cycle_warnings`; `Accounts.update_account/2` (or `Ecto.Changeset` + `Repo`).
- Produces: after a batch import, if `cycle_warnings != []`, the component lists each divergence with an "Atualizar" button that sets the account's `due_day` to `file_due_day` and re-estimates `closing_day`.

- [ ] **Step 1: Read the component**

Read `lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex`: how it stores/renders the import `result`, and how it handles events. Note where the result summary renders so you can add a cycle-divergence section.

- [ ] **Step 2: Write the failing test**

```elixir
# Render the component with an assign result that has one cycle_warning and
# assert the account name + "Atualizar" render. Then send the update event and
# assert the account's due_day was persisted. Follow the existing component-test
# style in the file; if there is no component test yet, drive it via the parent
# LiveView that mounts it, or test the update handler's effect on the DB.
```

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs`
Expected: FAIL.

- [ ] **Step 4: Implement**

Render a section when `@result && @result.cycle_warnings != []`:

```heex
<div :if={@result && @result.cycle_warnings != []} class="mt-4">
  <p class="text-xs font-bold uppercase opacity-60">Divergências de ciclo</p>
  <div :for={w <- @result.cycle_warnings} class="flex items-center justify-between text-xs py-1">
    <span>{w.account_name}: vencimento do arquivo (dia {w.file_due_day}) ≠ configurado (dia {w.configured_due_day})</span>
    <button class="btn btn-xs" phx-click="update_cycle" phx-value-account-id={w.account_id} phx-value-due-day={w.file_due_day} phx-target={@myself}>
      Atualizar
    </button>
  </div>
</div>
```

Add the handler (fetch the account by id, set `due_day`, re-estimate `closing_day`):

```elixir
  @impl true
  def handle_event("update_cycle", %{"account-id" => account_id, "due-day" => due_day}, socket) do
    due_day = String.to_integer(due_day)
    account = CashLens.Repo.get!(CashLens.Accounts.Account, account_id)
    est = CashLens.CreditCards.estimate_cycle(account)

    account
    |> Ecto.Changeset.change(due_day: due_day, closing_day: est.closing_day)
    |> CashLens.Repo.update()

    {:noreply, update(socket, :result, &drop_cycle_warning(&1, account_id))}
  end

  defp drop_cycle_warning(result, account_id) do
    %{result | cycle_warnings: Enum.reject(result.cycle_warnings, &(&1.account_id == account_id))}
  end
```

(Note: re-estimating `closing_day` here reads the account's boletos, which don't reflect the just-changed `due_day` — the estimate uses `due_day - 7` semantics only via `estimate_cycle`, which recomputes `due_day` from boletos too. If you'd rather keep the user's just-chosen `due_day` and only shift `closing_day` by the offset, compute `closing_day` as `due_day - 7` wrapped here instead of calling `estimate_cycle`. Pick the simpler correct one; the test asserts the account's `due_day` becomes `file_due_day`.)

- [ ] **Step 5: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test && mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs
git commit -m "feat(web): billing-cycle divergence summary on batch import"
```

---

## Post-implementation (operational)

After merge: on `/accounts`, for each credit card, click "Estimar do histórico", confirm/adjust the days, save. Then `mix cash_lens.recompute_competencia` (fixes existing non-boletos like Amazon Feb → Fev/26) and `mix cash_lens.reconcile_pending_statements` (competência changes may alter absorption eligibility). Verify on `/statements`.

## Self-Review

**Spec coverage:**
- Cycle fields + validation → Task 1.
- competência-from-cycle derivation (all cases + arithmetic) → Task 2.
- Estimation from boletos → Task 3.
- Import uses competencia_for → Task 4.
- Recompute existing → Task 5.
- Post-import divergence collection → Task 6.
- Accounts form UI (fields + estimate) → Task 7.
- Batch-import divergence summary + update → Task 8.

**Placeholder scan:** Tasks 6/8 tests defer to the existing importer/component harness with explicit "drive the helper directly, don't stub" instructions, and Task 8 flags the account-lookup API as read-first (adapting the warning entry if needed) — these are concrete adaptation notes, not silent TODOs. All logic steps carry full code.

**Type consistency:** `competencia_for/3` (Date|nil), `estimate_cycle/1` (`%{closing_day, due_day}`), `recompute_competencia/0` (int), `cycle_warnings` entry shape (`account_name, file, file_due_day, configured_due_day`) are consistent across Tasks 2/3/5/6/8. `closing_day`/`due_day` are the field names everywhere. Task 8 may add an `account_id` to the warning entry (flagged) — if so, Task 6's entry shape must include it; noted in Task 8.
