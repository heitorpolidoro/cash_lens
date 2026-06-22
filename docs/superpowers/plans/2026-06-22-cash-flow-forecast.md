# Previsão de Fluxo de Caixa Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Previsão" screen that detects recurring fixed bills/income from transaction history and projects the cash-flow of non-credit-card accounts forward, answering "when does the money run out" and "how much will I have on date X".

**Architecture:** A new `CashLens.Forecast` context owns a `recurring_items` table (one row per fixed-type category, with day-of-month + amount + active + manually_edited). Detection re-derives suggested values from the last 6 months of transactions; manual edits are protected from being overwritten until explicitly re-synced. A pure projection function walks future occurrences forward from the current non-credit-card balance. A new LiveView (`ForecastLive.Index`) at `/forecast` renders two summary cards and an editable table.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto/Postgres (existing stack — no new dependencies).

## Global Constraints

- Detection only considers transactions on accounts with `is_credit_card == false` (per spec: "considerando as contas não-cartão de crédito").
- A category needs **2+ occurrences** in the last 6 months to be suggested (spec: avoids one-off "fixed"-tagged transactions).
- `manually_edited: true` items are never touched by `sync_all/0`, only by `resync_item/1` (which also resets the flag to `false`).
- Projection horizon default: 90 days.
- All new Elixir test files use `async: false`, matching the rest of this codebase's existing tests (shared Postgres sandbox conventions in `test/cash_lens/accounting_test.exs`, `test/cash_lens_web/live/account_live_test.exs`).
- Run `mix format` before every commit (pre-commit hook enforces `mix format --check-formatted`).

---

## File Structure

| File | Responsibility |
|---|---|
| `priv/repo/migrations/20260622170000_create_recurring_items.exs` | Creates `recurring_items` table |
| `lib/cash_lens/forecast/recurring_item.ex` | Ecto schema + changeset |
| `lib/cash_lens/forecast.ex` | Context: CRUD, detection/sync, projection |
| `test/support/fixtures/forecast_fixtures.ex` | `recurring_item_fixture/1` |
| `test/cash_lens/forecast_test.exs` | Context unit tests |
| `lib/cash_lens_web/live/forecast_live/index.ex` | LiveView: render + event handlers |
| `lib/cash_lens_web/router.ex` | Add `/forecast` route (modify) |
| `lib/cash_lens_web/components/layouts/app.html.heex` | Add nav links, desktop + mobile (modify) |
| `test/cash_lens_web/live/forecast_live_test.exs` | LiveView tests |

---

### Task 1: Migration and `RecurringItem` schema

**Files:**
- Create: `priv/repo/migrations/20260622170000_create_recurring_items.exs`
- Create: `lib/cash_lens/forecast/recurring_item.ex`
- Create: `test/support/fixtures/forecast_fixtures.ex`
- Create: `lib/cash_lens/forecast.ex` (stub with `create_recurring_item/1` only — extended in later tasks)
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Produces: `CashLens.Forecast.RecurringItem` schema with fields `category_id, label, day_of_month, amount, active, manually_edited`.
- Produces: `CashLens.Forecast.create_recurring_item(attrs) :: {:ok, RecurringItem.t()} | {:error, Ecto.Changeset.t()}`.
- Produces: `CashLens.ForecastFixtures.recurring_item_fixture(attrs \\ %{}) :: RecurringItem.t()`.

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260622170000_create_recurring_items.exs
defmodule CashLens.Repo.Migrations.CreateRecurringItems do
  use Ecto.Migration

  def change do
    create table(:recurring_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :category_id, references(:categories, on_delete: :delete_all, type: :binary_id), null: false
      add :label, :string, null: false
      add :day_of_month, :integer, null: false
      add :amount, :decimal, precision: 15, scale: 2, null: false
      add :active, :boolean, null: false, default: true
      add :manually_edited, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recurring_items, [:category_id])
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `== Migrated 20260622170000 in 0.0s`

- [ ] **Step 3: Write the failing changeset test**

```elixir
# test/cash_lens/forecast_test.exs
defmodule CashLens.ForecastTest do
  use CashLens.DataCase, async: false

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem

  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures

  describe "create_recurring_item/1" do
    test "creates with valid attrs" do
      category = category_fixture(%{type: "fixed"})

      assert {:ok, %RecurringItem{} = item} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: category.name,
                 day_of_month: 10,
                 amount: "-100.00"
               })

      assert item.day_of_month == 10
      assert Decimal.equal?(item.amount, "-100.00")
      assert item.active == true
      assert item.manually_edited == false
    end

    test "rejects day_of_month outside 1..31" do
      category = category_fixture(%{type: "fixed"})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "x",
                 day_of_month: 32,
                 amount: "-10.00"
               })

      assert "must be less than or equal to 31" in errors_on(changeset).day_of_month
    end

    test "rejects amount of zero" do
      category = category_fixture(%{type: "fixed"})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "x",
                 day_of_month: 10,
                 amount: "0"
               })

      assert "não pode ser zero" in errors_on(changeset).amount
    end

    test "rejects a second item for the same category" do
      category = category_fixture(%{type: "fixed"})
      recurring_item_fixture(%{category_id: category.id})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "dup",
                 day_of_month: 5,
                 amount: "-1.00"
               })

      assert "has already been taken" in errors_on(changeset).category_id
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — `CashLens.Forecast` is undefined (module doesn't exist yet)

- [ ] **Step 5: Write the schema**

```elixir
# lib/cash_lens/forecast/recurring_item.ex
defmodule CashLens.Forecast.RecurringItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "recurring_items" do
    belongs_to :category, CashLens.Categories.Category
    field :label, :string
    field :day_of_month, :integer
    field :amount, :decimal
    field :active, :boolean, default: true
    field :manually_edited, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(recurring_item, attrs) do
    recurring_item
    |> cast(attrs, [:category_id, :label, :day_of_month, :amount, :active, :manually_edited])
    |> validate_required([:category_id, :label, :day_of_month, :amount])
    |> validate_number(:day_of_month, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> validate_amount_not_zero()
    |> unique_constraint(:category_id)
  end

  defp validate_amount_not_zero(changeset) do
    case get_field(changeset, :amount) do
      nil ->
        changeset

      amount ->
        if Decimal.equal?(amount, 0) do
          add_error(changeset, :amount, "não pode ser zero")
        else
          changeset
        end
    end
  end
end
```

- [ ] **Step 6: Write the context stub**

```elixir
# lib/cash_lens/forecast.ex
defmodule CashLens.Forecast do
  @moduledoc """
  The Forecast context: recurring fixed bills/income detected from
  transaction history, and the cash-flow projection built from them.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo
  alias CashLens.Forecast.RecurringItem

  @doc """
  Creates a recurring item directly. Used both by fixtures/tests and by
  the detection sync (Task 2) when a fixed category has no item yet.
  """
  def create_recurring_item(attrs) do
    %RecurringItem{}
    |> RecurringItem.changeset(attrs)
    |> Repo.insert()
  end
end
```

- [ ] **Step 7: Write the fixture**

```elixir
# test/support/fixtures/forecast_fixtures.ex
defmodule CashLens.ForecastFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Forecast` context.
  """

  def recurring_item_fixture(attrs \\ %{}) do
    category_id =
      Map.get(attrs, :category_id) ||
        CashLens.CategoriesFixtures.category_fixture(%{type: "fixed"}).id

    {:ok, item} =
      attrs
      |> Enum.into(%{
        category_id: category_id,
        label: "some fixed bill",
        day_of_month: 10,
        amount: "-100.00"
      })
      |> CashLens.Forecast.create_recurring_item()

    item
  end
end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: PASS (4 tests, 0 failures)

- [ ] **Step 9: Commit**

```bash
mix format
git add priv/repo/migrations/20260622170000_create_recurring_items.exs \
        lib/cash_lens/forecast/recurring_item.ex \
        lib/cash_lens/forecast.ex \
        test/support/fixtures/forecast_fixtures.ex \
        test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): add recurring_items table and schema"
```

---

### Task 2: Detection — `suggest_for_category/1`

**Files:**
- Modify: `lib/cash_lens/forecast.ex`
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `CashLens.Categories.Category` struct (`id`, `type`, `name`).
- Consumes: `CashLens.Transactions.Transaction` schema (`category_id`, `account_id`, `date`, `amount`).
- Consumes: `CashLens.Accounts.Account` schema (`is_credit_card`).
- Produces: `CashLens.Forecast.suggest_for_category(%Category{}) :: {:ok, %{"day_of_month" => integer(), "amount" => Decimal.t()}} | :insufficient_history`.

- [ ] **Step 1: Write the failing test**

```elixir
# Add to test/cash_lens/forecast_test.exs, inside CashLens.ForecastTest

  describe "suggest_for_category/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "returns :insufficient_history with fewer than 2 occurrences" do
      category = category_fixture(%{type: "fixed"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-50.00"
      })

      assert Forecast.suggest_for_category(category) == :insufficient_history
    end

    test "suggests the median day and the most recent amount" do
      category = category_fixture(%{type: "fixed"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-04-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-12],
        amount: "-52.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-55.00"
      })

      assert {:ok, %{"day_of_month" => 12, "amount" => amount}} =
               Forecast.suggest_for_category(category)

      assert Decimal.equal?(amount, "-55.00")
    end

    test "ignores transactions on credit card accounts" do
      category = category_fixture(%{type: "fixed"})
      cc_account = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: cc_account.id,
        category_id: category.id,
        date: ~D[2026-04-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: cc_account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      assert Forecast.suggest_for_category(category) == :insufficient_history
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — `Forecast.suggest_for_category/1 is undefined`

- [ ] **Step 3: Implement `suggest_for_category/1`**

```elixir
# In lib/cash_lens/forecast.ex, add aliases and the function

  alias CashLens.Accounts.Account
  alias CashLens.Categories.Category
  alias CashLens.Transactions.Transaction

  @history_months 6
  @min_occurrences 2

  @doc """
  Derives a {day_of_month, amount} suggestion for a fixed category from its
  transaction history (non-credit-card accounts only, last 6 months).
  Returns `:insufficient_history` when fewer than 2 occurrences exist.
  """
  def suggest_for_category(%Category{} = category) do
    since = Date.add(Date.utc_today(), -30 * @history_months)

    rows =
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where:
          t.category_id == ^category.id and a.is_credit_card == false and
            t.date >= ^since,
        select: %{date: t.date, amount: t.amount}
      )
      |> Repo.all()

    if length(rows) < @min_occurrences do
      :insufficient_history
    else
      days = rows |> Enum.map(& &1.date.day) |> Enum.sort()
      latest = Enum.max_by(rows, & &1.date, Date)
      {:ok, %{"day_of_month" => median(days), "amount" => latest.amount}}
    end
  end

  defp median(sorted_list) do
    Enum.at(sorted_list, div(length(sorted_list) - 1, 2))
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: PASS (7 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): detect recurring day/amount from category history"
```

---

### Task 3: `sync_all/0`, `resync_item/1`, `list_recurring_items/0`, `get_recurring_item!/1`

**Files:**
- Modify: `lib/cash_lens/forecast.ex`
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `Forecast.suggest_for_category/1` (Task 2), `Forecast.create_recurring_item/1` (Task 1).
- Consumes: `CashLens.Categories.list_categories/1` (existing — returns all categories).
- Produces: `Forecast.list_recurring_items() :: [RecurringItem.t()]`.
- Produces: `Forecast.get_recurring_item!(id) :: RecurringItem.t()`.
- Produces: `Forecast.sync_all() :: %{created: integer(), updated: integer()}`.
- Produces: `Forecast.resync_item(%RecurringItem{}) :: {:ok, RecurringItem.t()} | {:error, :insufficient_history}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# Add to test/cash_lens/forecast_test.exs, inside CashLens.ForecastTest

  describe "list_recurring_items/0 and get_recurring_item!/1" do
    test "lists items ordered by day_of_month" do
      recurring_item_fixture(%{day_of_month: 20})
      recurring_item_fixture(%{day_of_month: 5})

      assert [first, second] = Forecast.list_recurring_items()
      assert first.day_of_month == 5
      assert second.day_of_month == 20
    end

    test "get_recurring_item!/1 fetches by id" do
      item = recurring_item_fixture()
      assert Forecast.get_recurring_item!(item.id).id == item.id
    end
  end

  describe "sync_all/0" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "creates an item for a fixed category with enough history" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-52.00"
      })

      assert Forecast.sync_all() == %{created: 1, updated: 0}
      assert [item] = Forecast.list_recurring_items()
      assert item.label == "Água"
      assert item.day_of_month == 10
    end

    test "does not create an item for a category with insufficient history" do
      category_fixture(%{type: "fixed", name: "Sem histórico"})

      assert Forecast.sync_all() == %{created: 0, updated: 0}
      assert Forecast.list_recurring_items() == []
    end

    test "ignores variable categories" do
      category_fixture(%{type: "variable", name: "Mercado"})

      assert Forecast.sync_all() == %{created: 0, updated: 0}
    end

    test "updates an existing non-manually-edited item, leaves manually-edited ones alone" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-60.00"
      })

      auto_item = recurring_item_fixture(%{category_id: category.id, day_of_month: 1, amount: "-1.00"})

      assert Forecast.sync_all() == %{created: 0, updated: 1}

      reloaded = Forecast.get_recurring_item!(auto_item.id)
      assert reloaded.day_of_month == 10
      assert Decimal.equal?(reloaded.amount, "-60.00")
    end

    test "leaves a manually_edited item untouched" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-60.00"
      })

      edited_item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert Forecast.sync_all() == %{created: 0, updated: 0}

      reloaded = Forecast.get_recurring_item!(edited_item.id)
      assert reloaded.day_of_month == 1
      assert Decimal.equal?(reloaded.amount, "-1.00")
    end
  end

  describe "resync_item/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "forces an update and resets manually_edited to false" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-20],
        amount: "-99.00"
      })

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert {:ok, updated} = Forecast.resync_item(item)
      assert updated.day_of_month == 10
      assert Decimal.equal?(updated.amount, "-99.00")
      assert updated.manually_edited == false
    end

    test "returns an error when there isn't enough history" do
      item = recurring_item_fixture()
      assert Forecast.resync_item(item) == {:error, :insufficient_history}
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — `Forecast.list_recurring_items/0`, `get_recurring_item!/1`, `sync_all/0`, `resync_item/1` undefined

- [ ] **Step 3: Implement the functions**

```elixir
# In lib/cash_lens/forecast.ex, add:

  alias CashLens.Categories

  def list_recurring_items do
    RecurringItem
    |> order_by([r], asc: r.day_of_month)
    |> Repo.all()
  end

  def get_recurring_item!(id), do: Repo.get!(RecurringItem, id)

  @doc """
  Syncs all fixed categories against recurring_items: creates items for
  fixed categories that don't have one yet, and refreshes day/amount for
  existing items that haven't been manually edited.
  """
  def sync_all do
    fixed_categories = Categories.list_categories() |> Enum.filter(&(&1.type == "fixed"))
    existing_by_category = Map.new(list_recurring_items(), &{&1.category_id, &1})

    Enum.reduce(fixed_categories, %{created: 0, updated: 0}, fn category, acc ->
      sync_one(category, Map.get(existing_by_category, category.id), acc)
    end)
  end

  defp sync_one(_category, %RecurringItem{manually_edited: true}, acc), do: acc

  defp sync_one(category, nil, acc) do
    case suggest_for_category(category) do
      {:ok, suggestion} ->
        {:ok, _} =
          create_recurring_item(
            Map.merge(suggestion, %{"category_id" => category.id, "label" => category.name})
          )

        %{acc | created: acc.created + 1}

      :insufficient_history ->
        acc
    end
  end

  defp sync_one(category, %RecurringItem{} = item, acc) do
    case suggest_for_category(category) do
      {:ok, suggestion} ->
        {:ok, _} = item |> RecurringItem.changeset(suggestion) |> Repo.update()
        %{acc | updated: acc.updated + 1}

      :insufficient_history ->
        acc
    end
  end

  @doc """
  Forces a single item to re-derive day_of_month/amount from history and
  resets manually_edited to false.
  """
  def resync_item(%RecurringItem{} = item) do
    category = Categories.get_category!(item.category_id)

    case suggest_for_category(category) do
      {:ok, suggestion} ->
        item
        |> RecurringItem.changeset(Map.put(suggestion, "manually_edited", false))
        |> Repo.update()

      :insufficient_history ->
        {:error, :insufficient_history}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: PASS (15 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): add sync_all/0 and resync_item/1"
```

---

### Task 4: Manual edit and toggle — `manual_update/2`, `toggle_active/1`

**Files:**
- Modify: `lib/cash_lens/forecast.ex`
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `RecurringItem.changeset/2` (Task 1).
- Produces: `Forecast.manual_update(%RecurringItem{}, attrs) :: {:ok, RecurringItem.t()} | {:error, Ecto.Changeset.t()}`.
- Produces: `Forecast.toggle_active(%RecurringItem{}) :: {:ok, RecurringItem.t()}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# Add to test/cash_lens/forecast_test.exs, inside CashLens.ForecastTest

  describe "manual_update/2" do
    test "updates the fields and marks manually_edited" do
      item = recurring_item_fixture(%{day_of_month: 5, amount: "-10.00"})

      assert {:ok, updated} =
               Forecast.manual_update(item, %{"day_of_month" => "20", "amount" => "-15.00"})

      assert updated.day_of_month == 20
      assert Decimal.equal?(updated.amount, "-15.00")
      assert updated.manually_edited == true
    end

    test "returns an error changeset for an invalid day" do
      item = recurring_item_fixture()
      assert {:error, changeset} = Forecast.manual_update(item, %{"day_of_month" => "40"})
      assert "must be less than or equal to 31" in errors_on(changeset).day_of_month
    end
  end

  describe "toggle_active/1" do
    test "flips active from true to false and back" do
      item = recurring_item_fixture(%{active: true})

      assert {:ok, %{active: false} = toggled} = Forecast.toggle_active(item)
      assert {:ok, %{active: true}} = Forecast.toggle_active(toggled)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — `Forecast.manual_update/2` and `Forecast.toggle_active/1` undefined

- [ ] **Step 3: Implement the functions**

```elixir
# In lib/cash_lens/forecast.ex, add:

  @doc """
  Updates day_of_month and/or amount from the UI. Marks the item as
  manually_edited so future sync_all/0 calls leave it untouched.
  """
  def manual_update(%RecurringItem{} = item, attrs) do
    item
    |> RecurringItem.changeset(Map.put(attrs, "manually_edited", true))
    |> Repo.update()
  end

  def toggle_active(%RecurringItem{} = item) do
    item
    |> RecurringItem.changeset(%{"active" => !item.active})
    |> Repo.update()
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: PASS (18 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): add manual_update/2 and toggle_active/1"
```

---

### Task 5: Projection engine — `project/1`, `balance_on/2`, `next_income_date/1`

**Files:**
- Modify: `lib/cash_lens/forecast.ex`
- Test: `test/cash_lens/forecast_test.exs`

**Interfaces:**
- Consumes: `Forecast.list_recurring_items/0` (Task 3).
- Consumes: `CashLens.Accounting.list_latest_balances/0` (existing — returns balances preloaded with `:account`, each with `account_id` and `final_balance`).
- Consumes: `CashLens.Accounts.list_accounts/0` (existing — returns all accounts with `id, is_closed, is_credit_card, balance`).
- Produces: `Forecast.project(horizon_days \\ 90) :: %{starting_balance: Decimal.t(), occurrences: [%{date: Date.t(), item: RecurringItem.t(), balance_after: Decimal.t()}], zero_date: Date.t() | nil}`.
- Produces: `Forecast.balance_on(projection, date) :: Decimal.t()`.
- Produces: `Forecast.next_income_date(projection) :: Date.t()`.

- [ ] **Step 1: Write the failing tests**

```elixir
# Add to test/cash_lens/forecast_test.exs, inside CashLens.ForecastTest

  describe "project/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    setup do
      account = account_fixture(%{balance: "1000.00"})
      cc_account = account_fixture(%{balance: "5000.00", is_credit_card: true})
      %{account: account, cc_account: cc_account}
    end

    test "starting_balance excludes credit card and closed accounts", %{
      account: account,
      cc_account: cc_account
    } do
      closed = account_fixture(%{balance: "2000.00", is_closed: true})
      projection = Forecast.project()

      assert Decimal.equal?(projection.starting_balance, "1000.00")
      refute cc_account.is_credit_card == false
      assert closed.is_closed
    end

    test "inactive items don't appear in the projection" do
      recurring_item_fixture(%{day_of_month: 1, amount: "-2000.00", active: false})
      projection = Forecast.project()
      assert projection.occurrences == []
      assert projection.zero_date == nil
    end

    test "finds the date the balance goes negative", %{account: account} do
      today = Date.utc_today()
      future_day = today.day

      recurring_item_fixture(%{day_of_month: future_day, amount: "-2000.00"})

      projection = Forecast.project()

      assert projection.zero_date == today
      assert [%{date: ^today, balance_after: balance}] = projection.occurrences
      assert Decimal.equal?(balance, "-1000.00")
    end

    test "zero_date is nil when the balance never goes negative" do
      recurring_item_fixture(%{day_of_month: 15, amount: "-1.00"})
      projection = Forecast.project()
      assert projection.zero_date == nil
    end
  end

  describe "balance_on/2" do
    test "returns starting_balance when the date is before any occurrence" do
      projection = %{
        starting_balance: Decimal.new("100.00"),
        occurrences: [
          %{date: ~D[2026-07-01], item: nil, balance_after: Decimal.new("50.00")}
        ],
        zero_date: nil
      }

      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-06-01]), "100.00")
    end

    test "returns the cumulative balance as of the given date" do
      projection = %{
        starting_balance: Decimal.new("100.00"),
        occurrences: [
          %{date: ~D[2026-07-01], item: nil, balance_after: Decimal.new("50.00")},
          %{date: ~D[2026-07-10], item: nil, balance_after: Decimal.new("80.00")}
        ],
        zero_date: nil
      }

      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-07-05]), "50.00")
      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-07-10]), "80.00")
      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-12-31]), "80.00")
    end
  end

  describe "next_income_date/1" do
    test "returns the date of the first occurrence with a positive amount" do
      projection = %{
        starting_balance: Decimal.new("0"),
        occurrences: [
          %{date: ~D[2026-07-01], item: %{amount: Decimal.new("-50.00")}, balance_after: nil},
          %{date: ~D[2026-07-05], item: %{amount: Decimal.new("3000.00")}, balance_after: nil}
        ],
        zero_date: nil
      }

      assert Forecast.next_income_date(projection) == ~D[2026-07-05]
    end

    test "falls back to today + 30 days when there is no income item" do
      projection = %{starting_balance: Decimal.new("0"), occurrences: [], zero_date: nil}
      assert Forecast.next_income_date(projection) == Date.add(Date.utc_today(), 30)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: FAIL — `Forecast.project/1`, `balance_on/2`, `next_income_date/1` undefined

- [ ] **Step 3: Implement the functions**

```elixir
# In lib/cash_lens/forecast.ex, add:

  alias CashLens.Accounting
  alias CashLens.Accounts

  @default_horizon_days 90

  @doc """
  Projects the cash flow of non-credit-card accounts forward from today,
  applying every active recurring item's future occurrences within
  `horizon_days`.
  """
  def project(horizon_days \\ @default_horizon_days) do
    starting_balance = current_balance()
    today = Date.utc_today()
    horizon_end = Date.add(today, horizon_days)

    occurrences =
      list_recurring_items()
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(&future_occurrences(&1, today, horizon_end))
      |> Enum.sort_by(& &1.date, Date)
      |> with_running_balance(starting_balance)

    zero_date =
      occurrences
      |> Enum.find(&Decimal.negative?(&1.balance_after))
      |> case do
        nil -> nil
        occ -> occ.date
      end

    %{starting_balance: starting_balance, occurrences: occurrences, zero_date: zero_date}
  end

  @doc "Cumulative balance as of `date` (inclusive)."
  def balance_on(%{starting_balance: starting_balance, occurrences: occurrences}, date) do
    occurrences
    |> Enum.filter(&(Date.compare(&1.date, date) != :gt))
    |> List.last()
    |> case do
      nil -> starting_balance
      occ -> occ.balance_after
    end
  end

  @doc """
  Date of the next occurrence with a positive amount (income), or today + 30
  days when no income item is configured yet.
  """
  def next_income_date(%{occurrences: occurrences}) do
    occurrences
    |> Enum.find(&Decimal.positive?(&1.item.amount))
    |> case do
      nil -> Date.add(Date.utc_today(), 30)
      occ -> occ.date
    end
  end

  defp current_balance do
    balances_by_account =
      Map.new(Accounting.list_latest_balances(), &{&1.account_id, &1.final_balance})

    Accounts.list_accounts()
    |> Enum.reject(&(&1.is_closed or &1.is_credit_card))
    |> Enum.reduce(Decimal.new("0"), fn account, acc ->
      balance = Map.get(balances_by_account, account.id, account.balance)
      Decimal.add(acc, balance)
    end)
  end

  defp with_running_balance(occurrences, starting_balance) do
    {result, _final} =
      Enum.map_reduce(occurrences, starting_balance, fn occ, balance ->
        new_balance = Decimal.add(balance, occ.item.amount)
        {%{occ | balance_after: new_balance}, new_balance}
      end)

    result
  end

  defp future_occurrences(%RecurringItem{} = item, today, horizon_end) do
    first = next_occurrence_date(item.day_of_month, today)

    first
    |> Stream.iterate(&next_month_date(&1, item.day_of_month))
    |> Enum.take_while(&(Date.compare(&1, horizon_end) != :gt))
    |> Enum.map(&%{date: &1, item: item, balance_after: nil})
  end

  @doc false
  def next_occurrence_date(day_of_month, today) do
    this_month = clamp_day(today.year, today.month, day_of_month)

    if this_month.day >= today.day do
      this_month
    else
      next_month_date(today, day_of_month)
    end
  end

  defp next_month_date(date, day_of_month) do
    {year, month} = add_month(date.year, date.month)
    clamp_day(year, month, day_of_month)
  end

  defp add_month(year, 12), do: {year + 1, 1}
  defp add_month(year, month), do: {year, month + 1}

  defp clamp_day(year, month, day) do
    last_day = Date.new!(year, month, 1) |> Date.days_in_month()
    Date.new!(year, month, min(day, last_day))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cash_lens/forecast_test.exs`
Expected: PASS (24 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/forecast.ex test/cash_lens/forecast_test.exs
git commit -m "feat(forecast): add cash-flow projection algorithm"
```

---

### Task 6: `ForecastLive.Index`, route, and nav links

**Files:**
- Create: `lib/cash_lens_web/live/forecast_live/index.ex`
- Modify: `lib/cash_lens_web/router.ex`
- Modify: `lib/cash_lens_web/components/layouts/app.html.heex`
- Test: `test/cash_lens_web/live/forecast_live_test.exs`

**Interfaces:**
- Consumes: `Forecast.list_recurring_items/0`, `project/1`, `balance_on/2`, `next_income_date/1`, `sync_all/0`, `resync_item/1`, `toggle_active/1`, `manual_update/2`, `get_recurring_item!/1` (Tasks 1-5).
- Consumes: `CashLensWeb.Formatters.format_currency/1`, `format_date/1` (existing, auto-imported via `CashLensWeb, :live_view`/`:html` — confirm via `lib/cash_lens_web.ex`).

- [ ] **Step 1: Add the route**

```elixir
# lib/cash_lens_web/router.ex
# Inside the existing `live_session :default` block, after the "/installments" line:

      live "/installments", InstallmentLive.Index, :index
      live "/forecast", ForecastLive.Index, :index
```

- [ ] **Step 2: Add nav links (desktop menu)**

```heex
<!-- lib/cash_lens_web/components/layouts/app.html.heex -->
<!-- Inside the desktop <ul class="menu menu-horizontal ..."> after the "Parcelamentos" <li>: -->
          <li>
            <a href="/forecast" class="rounded-lg hover:bg-base-200 transition-all">Previsão</a>
          </li>
```

- [ ] **Step 3: Add nav link (mobile drawer)**

```heex
<!-- lib/cash_lens_web/components/layouts/app.html.heex -->
<!-- Inside the mobile <ul class="menu p-4 w-80 ..."> after the "Parcelamentos" <li>: -->
      <li>
        <a href="/forecast" class="font-bold">
          <.icon name="hero-chart-bar" class="size-5 mr-2" />Previsão
        </a>
      </li>
```

- [ ] **Step 4: Write the failing LiveView test**

```elixir
# test/cash_lens_web/live/forecast_live_test.exs
defmodule CashLensWeb.ForecastLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures
  import CashLens.TransactionsFixtures

  describe "Index" do
    test "renders the empty state when there are no recurring items", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/forecast")

      assert html =~ "Previsão"
      assert html =~ "Não fica negativo"
      assert html =~ "Nenhuma conta fixa detectada"
    end

    test "lists recurring items", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 12, amount: "-77.00"})

      {:ok, _live, html} = live(conn, ~p"/forecast")

      assert html =~ item.label
      assert html =~ "77,00"
    end

    test "sync_all creates items from history", %{conn: conn} do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-52.00"
      })

      {:ok, live, _html} = live(conn, ~p"/forecast")
      html = live |> element("button", "Sincronizar com Histórico") |> render_click()

      assert html =~ "Água"
    end

    test "toggle_active flips the item and updates the projection", %{conn: conn} do
      item = recurring_item_fixture(%{active: true})

      {:ok, live, _html} = live(conn, ~p"/forecast")
      live |> element("button[phx-click='toggle_active']") |> render_click()

      assert CashLens.Forecast.get_recurring_item!(item.id).active == false
    end

    test "update_day persists a manual edit", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 5})

      {:ok, live, _html} = live(conn, ~p"/forecast")

      live
      |> element("input[phx-value-id='#{item.id}'][phx-blur='update_day']")
      |> render_blur(%{"value" => "20"})

      reloaded = CashLens.Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 20
      assert reloaded.manually_edited == true
    end

    test "change_target_date recalculates the projected balance", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/forecast")

      html =
        live
        |> element("form[phx-change='change_target_date']")
        |> render_change(%{"date" => Date.add(Date.utc_today(), 5) |> Date.to_iso8601()})

      assert html =~ "Saldo em"
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `mix test test/cash_lens_web/live/forecast_live_test.exs`
Expected: FAIL — no route/LiveView module for `/forecast`

- [ ] **Step 6: Write the LiveView**

```elixir
# lib/cash_lens_web/live/forecast_live/index.ex
defmodule CashLensWeb.ForecastLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Forecast

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_projection(socket)}
  end

  defp assign_projection(socket) do
    items = Forecast.list_recurring_items()
    projection = Forecast.project()
    target_date = Forecast.next_income_date(projection)

    socket
    |> assign(:items, items)
    |> assign(:projection, projection)
    |> assign(:target_date, target_date)
    |> assign(:target_balance, Forecast.balance_on(projection, target_date))
  end

  @impl true
  def handle_event("sync_all", _params, socket) do
    Forecast.sync_all()

    {:noreply,
     socket
     |> assign_projection()
     |> put_flash(:success, "Sincronizado com o histórico.")}
  end

  @impl true
  def handle_event("resync_item", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.resync_item(item) do
      {:ok, _} ->
        {:noreply, assign_projection(socket)}

      {:error, :insufficient_history} ->
        {:noreply, put_flash(socket, :error, "Histórico insuficiente para ressincronizar.")}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)
    {:ok, _} = Forecast.toggle_active(item)
    {:noreply, assign_projection(socket)}
  end

  @impl true
  def handle_event("update_day", %{"id" => id, "value" => value}, socket) do
    apply_manual_update(socket, id, %{"day_of_month" => value}, "Dia inválido (use 1 a 31).")
  end

  @impl true
  def handle_event("update_amount", %{"id" => id, "value" => value}, socket) do
    apply_manual_update(socket, id, %{"amount" => value}, "Valor inválido.")
  end

  defp apply_manual_update(socket, id, attrs, error_message) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.manual_update(item, attrs) do
      {:ok, _} -> {:noreply, assign_projection(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, error_message)}
    end
  end

  @impl true
  def handle_event("change_target_date", %{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {:noreply,
         socket
         |> assign(:target_date, date)
         |> assign(:target_balance, Forecast.balance_on(socket.assigns.projection, date))}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Previsão
        <:subtitle>
          Projeção de saldo das contas não-cartão de crédito, com base nas suas contas fixas.
        </:subtitle>
        <:actions>
          <button phx-click="sync_all" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="size-4 mr-1" /> Sincronizar com Histórico
          </button>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title">Saldo Zera Em</div>
            <div class={[
              "stat-value text-2xl font-black",
              if(@projection.zero_date, do: "text-error", else: "text-success")
            ]}>
              <%= if @projection.zero_date do %>
                {format_date(@projection.zero_date)}
              <% else %>
                Não fica negativo
              <% end %>
            </div>
            <div class="stat-desc">Próximos 90 dias</div>
          </div>
        </div>

        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title flex items-center gap-2">
              <span>Saldo em</span>
              <form phx-change="change_target_date">
                <input
                  type="date"
                  name="date"
                  value={Date.to_iso8601(@target_date)}
                  class="input input-bordered input-xs"
                />
              </form>
            </div>
            <div class="stat-value text-2xl font-black text-primary">
              {format_currency(@target_balance)}
            </div>
          </div>
        </div>
      </div>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Conta</th>
              <th class="w-24 text-center">Dia</th>
              <th class="w-32 text-right">Valor</th>
              <th class="w-20 text-center">Ativo</th>
              <th class="w-20 text-center"></th>
              <th class="w-16"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @items} class={["hover", !item.active && "opacity-40"]}>
              <td class="font-bold">{item.label}</td>
              <td class="text-center">
                <input
                  type="number"
                  min="1"
                  max="31"
                  value={item.day_of_month}
                  phx-blur="update_day"
                  phx-value-id={item.id}
                  class="input input-bordered input-xs w-16 text-center"
                />
              </td>
              <td class="text-right">
                <input
                  type="number"
                  step="0.01"
                  value={item.amount}
                  phx-blur="update_amount"
                  phx-value-id={item.id}
                  class="input input-bordered input-xs w-28 text-right"
                />
              </td>
              <td class="text-center">
                <button phx-click="toggle_active" phx-value-id={item.id} class="btn btn-ghost btn-xs">
                  <.icon
                    name={if item.active, do: "hero-check-circle", else: "hero-x-circle"}
                    class={["size-5", if(item.active, do: "text-success", else: "text-base-300")]}
                  />
                </button>
              </td>
              <td class="text-center">
                <span :if={item.manually_edited} class="badge badge-ghost badge-sm text-[9px]">
                  Manual
                </span>
              </td>
              <td class="text-center">
                <button
                  phx-click="resync_item"
                  phx-value-id={item.id}
                  class="btn btn-ghost btn-xs"
                  title="Ressincronizar"
                >
                  <.icon name="hero-arrow-path" class="size-4" />
                </button>
              </td>
            </tr>
            <tr :if={@items == []}>
              <td colspan="6" class="text-center py-8 opacity-50">
                Nenhuma conta fixa detectada ainda. Clique em "Sincronizar com Histórico".
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix test test/cash_lens_web/live/forecast_live_test.exs`
Expected: PASS (6 tests, 0 failures)

- [ ] **Step 8: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures (no regressions in existing tests)

- [ ] **Step 9: Commit**

```bash
mix format
git add lib/cash_lens_web/live/forecast_live/index.ex \
        lib/cash_lens_web/router.ex \
        lib/cash_lens_web/components/layouts/app.html.heex \
        test/cash_lens_web/live/forecast_live_test.exs
git commit -m "feat(forecast): add /forecast screen with projection cards and editable items"
```

---

## Self-Review Notes

- **Spec coverage:** detecção por categoria (Task 2), sincronização híbrida com `manually_edited` e ressincronização forçada (Tasks 1, 3), saldo inicial excluindo cartão/encerradas (Task 5 `current_balance/0`), "saldo zera em" (Task 5 `zero_date`), "saldo em data configurável" pré-preenchida com a próxima receita (Task 5 `next_income_date/1`, Task 6 `mount`), tela dedicada com tabela editável (Task 6). All spec sections have a corresponding task.
- **Type consistency checked:** `RecurringItem` field names (`day_of_month`, `amount`, `active`, `manually_edited`, `category_id`, `label`) are identical across the schema (Task 1), context functions (Tasks 2-5), and LiveView (Task 6). `project/1`'s return shape (`starting_balance`, `occurrences`, `zero_date`) is used consistently by `balance_on/2`, `next_income_date/1` (Task 5), and the LiveView (Task 6).
- **No placeholders:** every step has complete, runnable code.
