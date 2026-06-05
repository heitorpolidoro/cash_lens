# Auto-Categorize Installments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When installment parcels are grouped, fill the category of parcels that have none — inheriting from a categorized sibling, falling back to AutoCategorizer on the cleaned description. Never overwrite an existing category.

**Architecture:** A new private step `fill_group_categories/3` runs at the end of `apply_present_parcels/4` in `lib/cash_lens/installments.ex`, after parcels are linked/cleaned. It reloads the group's transactions, derives a single category (mode of existing categories, else AutoCategorizer on the clean base description), and `Repo.update_all`s only the parcels with `category_id IS NULL`.

**Tech Stack:** Elixir 1.18, Ecto, ExUnit.

---

## File Structure

- `lib/cash_lens/installments.ex` — add `fill_group_categories/3` + helper(s); call it from `apply_present_parcels/4`; alias `AutoCategorizer`.
- `test/cash_lens/installments_apply_test.exs` — add a `describe "category backfill"` block.

Existing relevant code:
- `apply_present_parcels/4` ends with `Enum.each(present, fn {tx, d, billed} -> link_and_clean(tx, group, d, billed) end); length(present)`.
- `AutoCategorizer.categorize/1` (`lib/cash_lens/transactions/auto_categorizer.ex`) takes a map/struct with `:description` (and optional `:account_id`) and returns the params map, possibly with `:category_id` added.
- `Transaction` has `category_id`; `Category` (`CashLens.Categories.Category`) has `keywords` (comma/newline separated), matched case-insensitive substring against the upcased description.

---

## Task 1: Backfill categories for grouped parcels

**Files:**
- Modify: `lib/cash_lens/installments.ex`
- Test: `test/cash_lens/installments_apply_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/cash_lens/installments_apply_test.exs`. (Check the top of the file for existing imports/aliases — it uses `CashLens.Installments`, `Repo`, `Transaction`, `Ecto.Query`, and the transaction/account fixtures. Add `alias CashLens.Categories` / category creation as needed; create categories directly via `Repo.insert!`/`Categories` context — inspect `lib/cash_lens/categories.ex` for the create function and required fields, e.g. `name`, `slug`, `keywords`.)

```elixir
describe "category backfill on grouping" do
  setup do
    acc = account_fixture()
    %{acc: acc}
  end

  defp make_category(attrs) do
    # Adjust to the real Categories API / required fields.
    {:ok, cat} =
      CashLens.Categories.create_category(
        Map.merge(%{name: "Cat", slug: "cat-#{System.unique_integer([:positive])}"}, attrs)
      )

    cat
  end

  test "uncategorized parcel inherits a categorized sibling's category", %{acc: acc} do
    cat = make_category(%{name: "Saúde", slug: "saude-#{System.unique_integer([:positive])}"})

    # Two parcels of the same purchase; one already categorized, one not.
    t1 =
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "EC FARMA PARC 01/03 BR",
        date: ~D[2026-01-10],
        category_id: cat.id
      })

    _t2 =
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "EC FARMA PARC 02/03 BR",
        date: ~D[2026-01-10]
      })

    Installments.detect_and_apply(Repo.all(Transaction))

    cats =
      Repo.all(from t in Transaction, where: not is_nil(t.installment_group_id), select: t.category_id)

    assert Enum.all?(cats, &(&1 == cat.id))
    # sanity: the originally-categorized one is unchanged
    assert Repo.get(Transaction, t1.id).category_id == cat.id
  end

  test "all-uncategorized group is categorized via cleaned description keyword", %{acc: acc} do
    cat =
      make_category(%{
        name: "Mercado",
        slug: "mercado-#{System.unique_integer([:positive])}",
        keywords: "EC FARMA"
      })

    transaction_fixture(%{
      account_id: acc.id,
      amount: "-48.00",
      description: "EC FARMA PARC 01/03 BR",
      date: ~D[2026-01-10]
    })

    transaction_fixture(%{
      account_id: acc.id,
      amount: "-48.00",
      description: "EC FARMA PARC 02/03 BR",
      date: ~D[2026-01-10]
    })

    Installments.detect_and_apply(Repo.all(Transaction))

    cats =
      Repo.all(from t in Transaction, where: not is_nil(t.installment_group_id), select: t.category_id)

    assert cats != []
    assert Enum.all?(cats, &(&1 == cat.id))
  end

  test "existing category is never overwritten", %{acc: acc} do
    keep = make_category(%{name: "Manual", slug: "manual-#{System.unique_integer([:positive])}"})

    other =
      make_category(%{
        name: "Auto",
        slug: "auto-#{System.unique_integer([:positive])}",
        keywords: "EC FARMA"
      })

    t1 =
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "EC FARMA PARC 01/03 BR",
        date: ~D[2026-01-10],
        category_id: keep.id
      })

    transaction_fixture(%{
      account_id: acc.id,
      amount: "-48.00",
      description: "EC FARMA PARC 02/03 BR",
      date: ~D[2026-01-10]
    })

    Installments.detect_and_apply(Repo.all(Transaction))

    # t1 keeps its manual category, not overwritten by `other`.
    assert Repo.get(Transaction, t1.id).category_id == keep.id
  end

  test "group with no category and no keyword match stays uncategorized", %{acc: acc} do
    transaction_fixture(%{
      account_id: acc.id,
      amount: "-48.00",
      description: "ZZZ NOMATCH PARC 01/02 BR",
      date: ~D[2026-01-10]
    })

    transaction_fixture(%{
      account_id: acc.id,
      amount: "-48.00",
      description: "ZZZ NOMATCH PARC 02/02 BR",
      date: ~D[2026-01-10]
    })

    Installments.detect_and_apply(Repo.all(Transaction))

    cats =
      Repo.all(from t in Transaction, where: not is_nil(t.installment_group_id), select: t.category_id)

    assert Enum.all?(cats, &is_nil/1)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/installments_apply_test.exs -k "category backfill"`
Expected: FAIL (categories not being filled / inherited).

- [ ] **Step 3: Implement**

In `lib/cash_lens/installments.ex`:

(a) Add alias near the top with the other aliases:

```elixir
alias CashLens.Transactions.AutoCategorizer
```

(b) Call the backfill at the end of `apply_present_parcels/4`. Change:

```elixir
defp apply_present_parcels(base, total, amount_key, present) do
  group =
    find_or_create_group(
      base,
      total,
      amount_key,
      Enum.map(present, fn {tx, d, _} -> {tx, d} end)
    )

  Enum.each(present, fn {tx, d, billed} -> link_and_clean(tx, group, d, billed) end)
  length(present)
end
```

to:

```elixir
defp apply_present_parcels(base, total, amount_key, present) do
  group =
    find_or_create_group(
      base,
      total,
      amount_key,
      Enum.map(present, fn {tx, d, _} -> {tx, d} end)
    )

  Enum.each(present, fn {tx, d, billed} -> link_and_clean(tx, group, d, billed) end)

  account_id = present |> hd() |> elem(0) |> Map.get(:account_id)
  fill_group_categories(group, base, account_id)

  length(present)
end
```

(c) Add the new private functions (near `link_and_clean/4`):

```elixir
# Fills the category of the group's parcels that have none. Inherits the most
# common category among already-categorized parcels; if none exist, falls back to
# AutoCategorizer over the cleaned merchant-base description. Never overwrites an
# existing category and never touches the fingerprint.
defp fill_group_categories(group, base, account_id) do
  txs =
    Repo.all(
      from t in Transaction,
        where: t.installment_group_id == ^group.id,
        select: %{id: t.id, category_id: t.category_id}
    )

  case group_category_id(txs, base, account_id) do
    nil ->
      :ok

    category_id ->
      from(t in Transaction,
        where: t.installment_group_id == ^group.id and is_nil(t.category_id)
      )
      |> Repo.update_all(set: [category_id: category_id])

      :ok
  end
end

defp group_category_id(txs, base, account_id) do
  existing = txs |> Enum.map(& &1.category_id) |> Enum.reject(&is_nil/1)

  case existing do
    [] ->
      %{description: base, account_id: account_id}
      |> AutoCategorizer.categorize()
      |> Map.get(:category_id)

    ids ->
      ids
      |> Enum.frequencies()
      |> Enum.max_by(fn {_id, count} -> count end)
      |> elem(0)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/installments_apply_test.exs -k "category backfill"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/installments.ex test/cash_lens/installments_apply_test.exs
git commit -m "feat(installments): auto-categorize grouped parcels (fill empties, never overwrite)"
```

---

## Task 2: Verification & quality gates

- [ ] **Step 1: Run installment suites**

Run: `mix test test/cash_lens/installments_apply_test.exs test/cash_lens/installments_test.exs`
Expected: all PASS.

- [ ] **Step 2: Quality gates**

Run:
```bash
mix format
mix credo --strict lib/cash_lens/installments.ex
mix compile --warnings-as-errors --force
mix test
```
Expected: format clean; credo no issues; compile ok; full suite 0 failures.

- [ ] **Step 3: Commit any formatting fixes**

```bash
git add -A && git commit -m "chore(installments): formatting" || echo "nothing to commit"
```

---

## Self-Review Notes (author)

- **Spec coverage:** inheritance (mode) + AutoCategorizer fallback on clean `base` → `group_category_id/3`; fill-only-empties via `update_all ... where is_nil(category_id)`; never overwrite (covered by test 3); no fingerprint/balance/reimbursement changes. All spec points covered.
- **Type consistency:** `fill_group_categories/3`, `group_category_id/3` consistent; `AutoCategorizer.categorize/1` returns a map, `Map.get(:category_id)` may be nil → handled.
- **Edge:** empty `existing` → fallback; fallback nil → no update; existing categories → `update_all` skips non-null rows even within the same group.
- **Test API caveat:** the plan's `make_category/1` assumes a `CashLens.Categories.create_category/1`; the implementer must confirm the real function name and required fields (`name`, `slug`, `keywords`) in `lib/cash_lens/categories.ex` and adjust.
