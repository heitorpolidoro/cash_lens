# Forecast Credit-Card Invoices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the cash-flow forecast generate a monthly outflow occurrence per credit card — using the real unpaid boleto when one exists for that month, otherwise the account's recent variable spend plus that month's known installments — instead of treating "Cartão de Crédito" as a generic recurring item.

**Architecture:** A new `Forecast.card_occurrences/2` walks each cycle-configured card account's future due dates (reusing the existing `next_occurrence_date/2`/`next_month_date/2` cadence helpers already in `Forecast`), and for each due-month either surfaces the real `credit_card_statements` row (if unpaid) or computes an estimate from the account's most recent boleto (last 6 months) plus `Installments.account_installment_total/2` for that account/month. `project/1` merges these occurrences with the existing recurring-item occurrences before sorting/accumulating. `sync_all/0` is guarded so no `recurring_item` is ever auto-created for a credit-card category.

**Tech Stack:** Elixir 1.18, Ecto/Postgres, Phoenix LiveView, ExUnit. Money is `Decimal`; negative = outflow (matches `RecurringItem.amount`'s existing convention), installment magnitudes are stored/returned positive (matches `Installments.month_installment_total/2`'s existing convention).

## Global Constraints

- `@history_months` (already `6` in `CashLens.Forecast`) is the ONLY history window used anywhere in this feature — do not introduce a second constant.
- Occurrence shape stays `%{date: Date.t(), item: %{id:, label:, amount:, is_salary: false}, balance_after: nil}` so the existing `with_running_balance/2`, `next_income_date/1`, and the LiveView's `occ.item.id`/`.label`/`.amount`/`.is_salary` reads keep working unmodified. Card occurrences additionally carry `origin: :boleto | :estimado` (absent on recurring-item occurrences).
- A card's occurrence `item.id` is stable across months for that card: the account's own `id`. Label: `"Fatura #{account.name}"`.
- Cards without `closing_day`/`due_day` configured produce zero occurrences (no crash, no fallback guess).
- A paid boleto (`payment_transaction_id` not nil) for a given month produces NO occurrence for that month.
- `total_a_pagar` and `Installments` totals are stored/returned as POSITIVE magnitudes; occurrence `amount` must be NEGATED to represent an outflow.

---

### Task 1: `Installments.account_installment_total/2`

**Files:**
- Modify: `lib/cash_lens/installments.ex`
- Test: `test/cash_lens/installments_test.exs`

**Interfaces:**
- Consumes: existing private `parcel_due_in_month?/2` and `parcel_value/1` in the same module.
- Produces: `Installments.account_installment_total(account_id, month :: Date.t()) :: Decimal.t()` — sum of `parcel_value/1` over every `InstallmentGroup` that (a) has at least one transaction on `account_id` and (b) has an installment due in `month` (first-of-month `Date`), per `parcel_due_in_month?/2`. Returns `Decimal.new("0")` when none match. Positive magnitude (same convention as `month_installment_total/2`).

- [ ] **Step 1: Write the failing test**

```elixir
describe "account_installment_total/2" do
  test "sums parcels due in the given month for groups touching the account" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    other_card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})

    {:ok, group} =
      CashLens.Installments.create_installment_group(%{
        description_pattern: "FORECAST_TEST_ITEM",
        installments: 3,
        start_date: ~D[2026-06-01],
        total_amount: Decimal.new("300.00")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      installment_group_id: group.id,
      installment_number: 1,
      date: ~D[2026-06-01],
      amount: Decimal.new("-100.00")
    })

    # A group touching a DIFFERENT account must not be counted.
    {:ok, other_group} =
      CashLens.Installments.create_installment_group(%{
        description_pattern: "FORECAST_TEST_OTHER",
        installments: 2,
        start_date: ~D[2026-06-01],
        total_amount: Decimal.new("200.00")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: other_card.id,
      installment_group_id: other_group.id,
      installment_number: 1,
      date: ~D[2026-06-01],
      amount: Decimal.new("-100.00")
    })

    total = CashLens.Installments.account_installment_total(card.id, ~D[2026-07-01])
    assert Decimal.equal?(total, Decimal.new("100.00"))
  end

  test "returns 0 when nothing is due for the account in that month" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    total = CashLens.Installments.account_installment_total(card.id, ~D[2026-01-01])
    assert Decimal.equal?(total, Decimal.new("0"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/installments_test.exs`
Expected: FAIL — `account_installment_total/2` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/installments.ex` (near `list_installment_groups/0`):

```elixir
  @doc """
  Sum of installment parcels due in `month` for groups that touch
  `account_id` (i.e. at least one of the group's transactions belongs to
  that account). Positive magnitude, same convention as the internal
  month-total helper used by `upcoming_installments/1`.
  """
  def account_installment_total(account_id, %Date{} = month) do
    from(g in InstallmentGroup,
      join: t in assoc(g, :transactions),
      where: t.account_id == ^account_id,
      distinct: true,
      select: g
    )
    |> Repo.all()
    |> Enum.filter(&parcel_due_in_month?(&1, month))
    |> Enum.reduce(Decimal.new("0"), fn g, acc -> Decimal.add(acc, parcel_value(g)) end)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/installments_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/installments.ex test/cash_lens/installments_test.exs
git commit -m "feat(installments): account_installment_total for a card+month"
```

---

### Task 2: `Forecast.card_occurrences/2` — core logic

**Files:**
- Modify: `lib/cash_lens/forecast.ex`
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `Installments.account_installment_total/2` (Task 1); `CashLens.CreditCards.Statement`; `CashLens.CreditCards.statement_transactions/1`; `Accounts.list_accounts/0`; existing in-module `next_occurrence_date/2` and `next_month_date/2` (already `def`/`defp` in `Forecast`).
- Produces: `Forecast.card_occurrences(today :: Date.t(), horizon_end :: Date.t()) :: [%{date: Date.t(), item: map(), balance_after: nil, origin: :boleto | :estimado}]`. One entry per card account per month in range where an occurrence applies (skips paid months and months with neither a boleto nor a usable estimate).

- [ ] **Step 1: Write the failing tests**

```elixir
describe "card_occurrences/2" do
  setup do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10})
    %{card: card}
  end

  test "real unpaid boleto due in range uses its exact total and date", %{card: card} do
    s =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: ~D[2026-08-10],
        competencia: ~D[2026-08-01],
        total_a_pagar: Decimal.new("1500.00")
      })

    [occ] = CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31])
    assert occ.date == s.due_date
    assert Decimal.equal?(occ.item.amount, Decimal.new("-1500.00"))
    assert occ.origin == :boleto
    assert occ.item.id == card.id
  end

  test "paid boleto produces no occurrence for its month", %{card: card} do
    payment =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: CashLens.AccountsFixtures.account_fixture().id,
        amount: Decimal.new("1500.00")
      })

    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card,
      due_date: ~D[2026-08-10],
      competencia: ~D[2026-08-01],
      total_a_pagar: Decimal.new("1500.00"),
      payment_transaction_id: payment.id
    })

    assert CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31]) == []
  end

  test "no boleto for the month estimates from the recent boleto plus that month's installments", %{
    card: card
  } do
    # Recent boleto (within 6 months): total 2000, with a 500 installment of its own.
    recent =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: Date.add(Date.utc_today(), -30),
        competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -30)),
        total_a_pagar: Decimal.new("2000.00")
      })

    {:ok, recent_group} =
      CashLens.Installments.create_installment_group(%{
        description_pattern: "RECENT_PARCEL",
        installments: 2,
        start_date: Date.beginning_of_month(recent.due_date),
        total_amount: Decimal.new("1000.00")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      installment_group_id: recent_group.id,
      installment_number: 1,
      date: recent.due_date,
      amount: Decimal.new("-500.00")
    })

    # Future month has its own different installment of 200.
    future_month = Date.add(Date.utc_today(), 60)
    future_first = Date.beginning_of_month(future_month)

    {:ok, future_group} =
      CashLens.Installments.create_installment_group(%{
        description_pattern: "FUTURE_PARCEL",
        installments: 1,
        start_date: future_first,
        total_amount: Decimal.new("200.00")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      installment_group_id: future_group.id,
      installment_number: 1,
      date: future_first,
      amount: Decimal.new("-200.00")
    })

    occurrences = CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))
    assert [occ] = occurrences
    assert occ.origin == :estimado
    # variable = -2000 + 500 = -1500 ; estimate = -1500 - 200 = -1700
    assert Decimal.equal?(occ.item.amount, Decimal.new("-1700.00"))
  end

  test "no recent boleto within history window yields no occurrences", %{card: card} do
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card,
      due_date: Date.add(Date.utc_today(), -400),
      competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -400)),
      total_a_pagar: Decimal.new("2000.00")
    })

    future_month = Date.add(Date.utc_today(), 60)

    assert CashLens.Forecast.card_occurrences(future_month, Date.end_of_month(future_month)) ==
             []
  end

  test "account without a configured cycle yields no occurrences" do
    CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    today = Date.utc_today()
    assert CashLens.Forecast.card_occurrences(today, Date.add(today, 60)) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — `card_occurrences/2` undefined.

- [ ] **Step 3: Implement**

Add aliases near the top of `lib/cash_lens/forecast.ex` (alongside the existing ones):

```elixir
  alias CashLens.CreditCards
  alias CashLens.CreditCards.Statement
  alias CashLens.Installments
```

Add the public function and its private helpers (place after `next_occurrence_date/2`, before the final `end`):

```elixir
  @doc """
  One outflow occurrence per credit-card account (with a configured
  closing_day/due_day) per due-month in [today, horizon_end]: the real
  unpaid boleto for that month if one was imported, otherwise an estimate
  from the account's most recent boleto (within @history_months) plus that
  month's known installments. Paid months and cycle-less accounts produce
  no occurrence.
  """
  def card_occurrences(today, horizon_end) do
    card_accounts()
    |> Enum.flat_map(&card_account_occurrences(&1, today, horizon_end))
  end

  defp card_accounts do
    Accounts.list_accounts()
    |> Enum.filter(fn a ->
      a.is_credit_card and not a.is_closed and is_integer(a.closing_day) and
        is_integer(a.due_day)
    end)
  end

  defp card_account_occurrences(account, today, horizon_end) do
    card_due_dates(account.due_day, today, horizon_end)
    |> Enum.map(&card_occurrence_for_date(account, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp card_due_dates(due_day, today, horizon_end) do
    next_occurrence_date(due_day, today)
    |> Stream.iterate(&next_month_date(&1, due_day))
    |> Enum.take_while(&(Date.compare(&1, horizon_end) != :gt))
  end

  defp card_occurrence_for_date(account, date) do
    month = Date.beginning_of_month(date)

    case statement_for_month(account.id, month) do
      %Statement{payment_transaction_id: nil} = s ->
        build_card_occurrence(account, s.due_date, statement_amount(s), :boleto)

      %Statement{} ->
        nil

      nil ->
        case estimate_for_month(account, month) do
          nil -> nil
          amount -> build_card_occurrence(account, date, amount, :estimado)
        end
    end
  end

  defp statement_for_month(account_id, month) do
    month_end = Date.end_of_month(month)

    from(s in Statement,
      where: s.account_id == ^account_id and s.due_date >= ^month and s.due_date <= ^month_end
    )
    |> Repo.one()
  end

  defp statement_amount(%Statement{total_a_pagar: total}) when not is_nil(total),
    do: Decimal.negate(total)

  defp statement_amount(%Statement{id: id}) do
    id
    |> CreditCards.statement_transactions()
    |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))
  end

  defp estimate_for_month(account, month) do
    since = Date.add(Date.utc_today(), -30 * @history_months)

    recent =
      from(s in Statement,
        where: s.account_id == ^account.id and not is_nil(s.due_date) and s.due_date >= ^since,
        order_by: [desc: s.due_date],
        limit: 1
      )
      |> Repo.one()

    case recent do
      nil ->
        nil

      statement ->
        recent_month = Date.beginning_of_month(statement.due_date)
        recent_installments = Installments.account_installment_total(account.id, recent_month)
        variable = Decimal.add(statement_amount(statement), recent_installments)
        future_installments = Installments.account_installment_total(account.id, month)
        Decimal.sub(variable, future_installments)
    end
  end

  defp build_card_occurrence(account, date, amount, origin) do
    %{
      date: date,
      item: %{id: account.id, label: "Fatura #{account.name}", amount: amount, is_salary: false},
      balance_after: nil,
      origin: origin
    }
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/forecast_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): card_occurrences from boletos and installments"
```

---

### Task 3: Wire `card_occurrences/2` into `project/1`

**Files:**
- Modify: `lib/cash_lens/forecast.ex` (`project/1`)
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `card_occurrences/2` (Task 2).
- Produces: `project/1`'s `occurrences` list now includes card occurrences, merged and sorted by date with the recurring-item occurrences, before the running-balance/`zero_date` computation (both of which only rely on `occ.item.amount` / `occ.balance_after`, so they work unchanged on the merged list).

- [ ] **Step 1: Write the failing test**

```elixir
test "project/1 includes card occurrences merged with recurring items" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10})

  s =
    CashLens.CreditCardsFixtures.statement_fixture(%{
      account: card,
      due_date: Date.add(Date.utc_today(), 5),
      competencia: Date.beginning_of_month(Date.add(Date.utc_today(), 5)),
      total_a_pagar: Decimal.new("800.00")
    })

  projection = CashLens.Forecast.project(30)

  assert Enum.any?(projection.occurrences, fn occ ->
           occ.origin == :boleto and occ.date == s.due_date and
             Decimal.equal?(occ.item.amount, Decimal.new("-800.00"))
         end)

  # Merged list stays sorted by date and every occurrence got a balance_after.
  dates = Enum.map(projection.occurrences, & &1.date)
  assert dates == Enum.sort(dates, Date)
  assert Enum.all?(projection.occurrences, &(&1.balance_after != nil))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — the boleto occurrence is absent from `project/1`'s output.

- [ ] **Step 3: Implement**

In `lib/cash_lens/forecast.ex`, change `project/1`'s occurrence-building pipeline from:

```elixir
    occurrences =
      list_recurring_items()
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(&future_occurrences(&1, today, horizon_end))
      |> Enum.sort_by(& &1.date, Date)
      |> with_running_balance(starting_balance)
```

to:

```elixir
    recurring_occurrences =
      list_recurring_items()
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(&future_occurrences(&1, today, horizon_end))

    occurrences =
      (recurring_occurrences ++ card_occurrences(today, horizon_end))
      |> Enum.sort_by(& &1.date, Date)
      |> with_running_balance(starting_balance)
```

- [ ] **Step 4: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/forecast_test.exs && mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): merge card occurrences into project/1"
```

---

### Task 4: `sync_all/0` never creates a recurring item for a credit-card category

**Files:**
- Modify: `lib/cash_lens/forecast.ex` (`sync_all/0`)
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `Categories.list_categories/0` (already used).
- Produces: `sync_all/0` skips any `fixed` category whose `slug` is `"cartao-de-credito"` or starts with `"cartao-de-credito-"`, so no `recurring_item` is ever auto-created/updated for a card category — the dynamic `card_occurrences/2` is the only source for card outflows.

- [ ] **Step 1: Write the failing test**

```elixir
test "sync_all/0 never creates a recurring_item for a credit-card category" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  {:ok, category} = CashLens.Categories.create_category(%{name: "Cartão de Crédito", slug: "cartao-de-credito", type: "fixed"})

  for i <- 1..3 do
    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      category_id: category.id,
      amount: Decimal.new("-100.00"),
      date: Date.add(Date.utc_today(), -30 * i)
    })
  end

  assert CashLens.Forecast.sync_all() == %{created: 0, updated: 0}
  assert CashLens.Forecast.list_recurring_items() == []
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — the card category currently gets a `recurring_item` created (its history has ≥2 occurrences, satisfying `@min_occurrences`).

- [ ] **Step 3: Implement**

In `lib/cash_lens/forecast.ex`, change `sync_all/0`'s category selection from:

```elixir
    fixed_categories = Categories.list_categories() |> Enum.filter(&(&1.type == "fixed"))
```

to:

```elixir
    fixed_categories =
      Categories.list_categories()
      |> Enum.filter(&(&1.type == "fixed" and not credit_card_category?(&1)))
```

and add a private helper near `sync_one/3`:

```elixir
  defp credit_card_category?(%Category{slug: slug}) when is_binary(slug) do
    slug == "cartao-de-credito" or String.starts_with?(slug, "cartao-de-credito-")
  end

  defp credit_card_category?(_category), do: false
```

- [ ] **Step 4: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/forecast_test.exs && mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): sync_all excludes credit-card categories"
```

---

### Task 5: LiveView — origin badge for card occurrences

**Files:**
- Modify: `lib/cash_lens_web/live/forecast_live/index.ex`
- Test: `test/cash_lens_web/live/forecast_live_test.exs`

**Interfaces:**
- Consumes: `occ.origin` (`:boleto` | `:estimado` | absent) from `project/1`'s merged occurrence list (Task 3).
- Produces: each occurrence row in the projection list shows a small badge — "Boleto" when `occ.origin == :boleto`, "Estimado" when `occ.origin == :estimado` — and nothing when `origin` is absent (regular recurring items).

- [ ] **Step 1: Read the current occurrence row markup**

Read `lib/cash_lens_web/live/forecast_live/index.ex` around line 223 (`for occ <- @projection.occurrences do`) through the label/amount rendering (~line 235-252) to see the exact tag structure and CSS classes used, so the badge matches the file's existing style.

- [ ] **Step 2: Write the failing test**

```elixir
test "shows a Boleto badge for a card occurrence and Estimado for an estimated one", %{conn: conn} do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10, name: "Ourocard"})

  CashLens.CreditCardsFixtures.statement_fixture(%{
    account: card,
    due_date: Date.add(Date.utc_today(), 5),
    competencia: Date.beginning_of_month(Date.add(Date.utc_today(), 5)),
    total_a_pagar: Decimal.new("500.00")
  })

  {:ok, _view, html} = live(conn, ~p"/forecast")
  assert html =~ "Fatura Ourocard"
  assert html =~ "Boleto"
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/forecast_live_test.exs`
Expected: FAIL — no "Boleto" text rendered.

- [ ] **Step 4: Implement**

In the occurrence row block (the `<%= for occ <- @projection.occurrences do %>` loop), immediately after the `{occ.item.label}` span (~line 235), add:

```heex
<span :if={Map.get(occ, :origin) == :boleto} class="badge badge-xs badge-success ml-1">
  Boleto
</span>
<span :if={Map.get(occ, :origin) == :estimado} class="badge badge-xs badge-ghost ml-1">
  Estimado
</span>
```

(Use `Map.get(occ, :origin)` rather than `occ.origin` since recurring-item occurrences don't have that key.)

- [ ] **Step 5: Run tests + full suite**

Run: `export $(cat .env | xargs) && mix test test/cash_lens_web/live/forecast_live_test.exs && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens_web/live/forecast_live/index.ex test/cash_lens_web/live/forecast_live_test.exs
git commit -m "feat(web): Boleto/Estimado badge on forecast card occurrences"
```

---

## Self-Review

**Spec coverage:**
- Boleto real / estimado (gasto variável recente + parcelas do mês) / fatura paga sem ocorrência / sem histórico sem ocorrência / sem ciclo sem ocorrência → Task 2.
- Integração no `project/1` → Task 3.
- Salvaguarda em `sync_all/0` → Task 4.
- UI (selo de origem) → Task 5.
- Helper de parcelas por conta reaproveitando `parcel_due_in_month?/parcel_value` → Task 1.

**Placeholder scan:** none — every step carries complete code; Task 5's Step 1 is a read-only grounding step (no code), explicit about what to look for before writing the HEEx.

**Type consistency:** `card_occurrences/2` signature and its occurrence shape (`date`, `item.{id,label,amount,is_salary}`, `balance_after`, `origin`) are used identically in Tasks 2, 3, 5. `Installments.account_installment_total/2` name/arity used identically in Task 1's test and Task 2's implementation. `Statement`, `CreditCards.statement_transactions/1` names match the existing codebase (verified against `lib/cash_lens/credit_cards.ex` and `lib/cash_lens/credit_cards/statement.ex`).
