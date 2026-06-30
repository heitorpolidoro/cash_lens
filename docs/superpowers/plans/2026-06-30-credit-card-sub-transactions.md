# Sub-transações para faturas de cartão de crédito — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the credit-card-bill "transfer" mirror hack with a real parent/child transaction model: the bill payment gets categorized as "Cartão de Crédito" and the real invoice line items become its sub-transactions, matched automatically by batch sum/date with a manual reconciliation screen for the rest.

**Architecture:** A new self-referencing `parent_transaction_id` on `transactions`, a new `CreditCardMatcher` module (sibling of `TransferMatcher`) that links N children to 1 parent by batch-sum/date matching, a branch in `TransferRuleApplier` for credit-card destinations, anti-join filters in the category-breakdown/summary queries, a new `/credit_card_links` LiveView screen, and a one-off data migration for historical transfer-linked pairs.

**Tech Stack:** Elixir 1.18 / Phoenix 1.8 / LiveView / Ecto 3.13 / PostgreSQL.

## Global Constraints

- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` must all pass (`mix quality_check`) before any commit is considered done.
- Binary IDs everywhere — no integer PKs (see root `CLAUDE.md`).
- Context boundaries are sacred: LiveViews call `CashLens.Transactions` / `CashLens.Categories` / `CashLens.Accounts`, never `Ecto` schemas directly.
- Date tolerance for automatic matching: **±5 days** (`@tolerance_days 5` in `CreditCardMatcher`).
- New category slug: **`cartao-de-credito`**, name **"Cartão de Crédito"**, `type: "variable"`.
- Spec: [docs/superpowers/specs/2026-06-30-credit-card-sub-transactions-design.md](../specs/2026-06-30-credit-card-sub-transactions-design.md) — every task below implements a numbered section from that file; section numbers are referenced in each task.

---

### Task 1: Schema — `parent_transaction_id`

**Spec section:** 1.

**Files:**
- Create: `priv/repo/migrations/20260701000000_add_parent_transaction_id_to_transactions.exs`
- Modify: `lib/cash_lens/transactions/transaction.ex`
- Test: `test/cash_lens/transactions/transaction_test.exs`

**Interfaces:**
- Produces: `Transaction.changeset/2` now accepts `:parent_transaction_id` (binary_id, nilable, FK to `transactions.id`). Every later task that links/unlinks children sets this field via `Repo.update_all(set: [parent_transaction_id: ...])` directly (bypassing the changeset, same pattern already used by `TransferMatcher.link_pair/3`), so the changeset cast is only exercised by manual edits / tests.

- [ ] **Step 1: Write the failing test**

```elixir
# test/cash_lens/transactions/transaction_test.exs — add to existing file
describe "parent_transaction_id" do
  test "changeset accepts parent_transaction_id" do
    parent_id = Ecto.UUID.generate()

    changeset =
      Transaction.changeset(%Transaction{}, %{
        date: ~D[2026-01-01],
        description: "Uber",
        amount: "-30.00",
        account_id: Ecto.UUID.generate(),
        parent_transaction_id: parent_id
      })

    assert Ecto.Changeset.get_change(changeset, :parent_transaction_id) == parent_id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/transactions/transaction_test.exs -v --only line:0` — actually run the whole file:
Run: `mix test test/cash_lens/transactions/transaction_test.exs`
Expected: FAIL — `get_change(changeset, :parent_transaction_id)` returns `nil` because the field is not yet cast.

- [ ] **Step 3: Add the migration**

```elixir
# priv/repo/migrations/20260701000000_add_parent_transaction_id_to_transactions.exs
defmodule CashLens.Repo.Migrations.AddParentTransactionIdToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :parent_transaction_id,
          references(:transactions, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:transactions, [:parent_transaction_id])
  end
end
```

Run: `mix ecto.migrate`
Expected: `[info] == Running ... AddParentTransactionIdToTransactions.change/0 forward` then `:ok`.

- [ ] **Step 4: Add the field + cast to the schema**

In `lib/cash_lens/transactions/transaction.ex`, add the field next to `installment_number` (line 31):

```elixir
    field :installment_number, :integer
    field :parent_transaction_id, :binary_id
```

Add `:parent_transaction_id` to the `cast/3` list in `changeset/2`:

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
      :installment_group_id,
      :installment_number,
      :occurrence_index,
      :parent_transaction_id
    ])
```

Add a `foreign_key_constraint` right after `unique_constraint(:fingerprint)`:

```elixir
    |> validate_required([:date, :description, :amount, :account_id])
    |> put_dedup_key()
    |> generate_fingerprint()
    |> unique_constraint(:fingerprint)
    |> foreign_key_constraint(:parent_transaction_id)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/cash_lens/transactions/transaction_test.exs`
Expected: PASS.

- [ ] **Step 6: Run full quality gate for this slice**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: no warnings, no formatting diffs, no Credo issues.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20260701000000_add_parent_transaction_id_to_transactions.exs lib/cash_lens/transactions/transaction.ex test/cash_lens/transactions/transaction_test.exs
git commit -m "feat(transactions): add parent_transaction_id for sub-transactions"
```

---

### Task 2: Seed the "Cartão de Crédito" category

**Spec section:** 2.

**Files:**
- Modify: `priv/repo/seeds.exs`

**Interfaces:**
- Produces: a `categories` row with `slug: "cartao-de-credito"`, `name: "Cartão de Crédito"`, `type: "variable"` (schema default), reachable via `CashLens.Categories.get_category_by_slug("cartao-de-credito")` after seeds run. Every later task that needs this category in production/dev relies on this seed; tests create their own category via `CategoriesFixtures.category_fixture/1` and do not depend on seeds.

- [ ] **Step 1: Add the seed row**

```elixir
# priv/repo/seeds.exs
alias CashLens.Repo
alias CashLens.Categories.Category

Repo.insert!(%Category{name: "Valor Inicial", slug: "initial_value"}, on_conflict: :nothing)
Repo.insert!(%Category{name: "Transferência", slug: "transfer"}, on_conflict: :nothing)
Repo.insert!(%Category{name: "Cartão de Crédito", slug: "cartao-de-credito"}, on_conflict: :nothing)
```

- [ ] **Step 2: Verify locally**

Run: `mix run priv/repo/seeds.exs`
Expected: no errors. Then:
Run: `mix run -e 'IO.inspect(CashLens.Categories.get_category_by_slug("cartao-de-credito"))'`
Expected: prints a `%CashLens.Categories.Category{...slug: "cartao-de-credito"...}` struct, not `nil`. Re-running `mix run priv/repo/seeds.exs` a second time must not error (idempotent `on_conflict: :nothing`).

- [ ] **Step 3: Commit**

```bash
git add priv/repo/seeds.exs
git commit -m "feat(categories): seed Cartão de Crédito category"
```

---

### Task 3: `CreditCardMatcher.match_batch/1`

**Spec section:** 4 (forward direction: new import batch → find existing payment).

**Files:**
- Create: `lib/cash_lens/transactions/credit_card_matcher.ex`
- Test: `test/cash_lens/transactions/credit_card_matcher_test.exs`

**Interfaces:**
- Consumes: `CashLens.Accounts.Account` (`is_credit_card` field), `CashLens.Categories.get_category_by_slug/1`, `CashLens.Transactions.Transaction` struct fields (`id`, `account_id`, `amount`, `date`, `category_id`, `parent_transaction_id`, `inserted_at`).
- Produces:
  - `CreditCardMatcher.match_batch([Transaction.t()]) :: {:ok, Ecto.UUID.t()} | :no_match | :ambiguous | :not_credit_card_batch`
  - (private helpers `credit_card_category/0`, `filter_credit_card_orphans/1`, `candidate_payments/5`, `pick_unambiguous_candidate/2`, `link_batch/2` — used internally and reused by Task 4).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/cash_lens/transactions/credit_card_matcher_test.exs
defmodule CashLens.Transactions.CreditCardMatcherTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction

  defp credit_card_category, do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

  defp card_account, do: account_fixture(%{is_credit_card: true})
  defp checking_account, do: account_fixture(%{is_credit_card: false})

  defp purchase(account, amount, date) do
    transaction_fixture(%{account_id: account.id, amount: amount, date: date, description: "compra"})
  end

  defp payment(account, category, amount, date) do
    transaction_fixture(%{
      account_id: account.id,
      category_id: category.id,
      amount: amount,
      date: date,
      description: "pagamento fatura"
    })
  end

  describe "match_batch/1" do
    test "links the batch to a payment when the sum and date match" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()

      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      p2 = purchase(card, "-70.00", ~D[2026-03-03])
      pay = payment(checking, category, "-100.00", ~D[2026-03-05])

      assert {:ok, parent_id} = CreditCardMatcher.match_batch([p1, p2])
      assert parent_id == pay.id

      assert Repo.get!(Transaction, p1.id).parent_transaction_id == pay.id
      assert Repo.get!(Transaction, p2.id).parent_transaction_id == pay.id
    end

    test "returns :no_match when no payment has the matching amount" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      payment(checking, category, "-999.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_batch([p1]) == :no_match
    end

    test "returns :no_match when the matching payment is outside the date tolerance" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      payment(checking, category, "-30.00", ~D[2026-03-20])

      assert CreditCardMatcher.match_batch([p1]) == :no_match
    end

    test "returns :ambiguous and links nothing when two candidates tie on date diff" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-05])
      pay_a = payment(checking, category, "-30.00", ~D[2026-03-03])
      pay_b = payment(checking, category, "-30.00", ~D[2026-03-07])

      assert CreditCardMatcher.match_batch([p1]) == :ambiguous
      assert Repo.get!(Transaction, p1.id).parent_transaction_id == nil
      assert Repo.get!(Transaction, pay_a.id).parent_transaction_id == nil
      assert Repo.get!(Transaction, pay_b.id).parent_transaction_id == nil
    end

    test "nets out a refund mixed with purchases" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-100.00", ~D[2026-03-01])
      refund = purchase(card, "20.00", ~D[2026-03-02])
      pay = payment(checking, category, "-80.00", ~D[2026-03-05])

      assert {:ok, parent_id} = CreditCardMatcher.match_batch([p1, refund])
      assert parent_id == pay.id
    end

    test "returns :not_credit_card_batch when no transaction is from a credit-card account" do
      checking = checking_account()
      p1 = purchase(checking, "-30.00", ~D[2026-03-01])

      assert CreditCardMatcher.match_batch([p1]) == :not_credit_card_batch
    end

    test "returns :not_credit_card_batch when the category does not exist" do
      card = card_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])

      assert CreditCardMatcher.match_batch([p1]) == :not_credit_card_batch
    end

    test "ignores transactions that already have a parent" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      pay = payment(checking, category, "-30.00", ~D[2026-03-05])
      p1 = purchase(card, "-30.00", ~D[2026-03-01])

      {1, _} =
        from(t in Transaction, where: t.id == ^p1.id)
        |> Repo.update_all(set: [parent_transaction_id: pay.id])

      reloaded = Repo.get!(Transaction, p1.id)
      assert CreditCardMatcher.match_batch([reloaded]) == :not_credit_card_batch
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions/credit_card_matcher_test.exs`
Expected: FAIL — `CreditCardMatcher` module does not exist (`UndefinedFunctionError` / compile error).

- [ ] **Step 3: Implement the module**

```elixir
# lib/cash_lens/transactions/credit_card_matcher.ex
defmodule CashLens.Transactions.CreditCardMatcher do
  @moduledoc """
  Links credit-card invoice line items (children) to their bill-payment
  transaction (parent). Mirrors `TransferMatcher`, but matches the SUM of
  N children against 1 parent instead of a strict 1:1 pair.
  """
  import Ecto.Query

  alias CashLens.Accounts.Account
  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  @tolerance_days 5

  @doc """
  Tries to link a freshly-imported batch of credit-card transactions to an
  existing, still-childless "Cartão de Crédito" payment transaction, by
  exact sum and date within #{@tolerance_days} days.
  """
  @spec match_batch([Transaction.t()]) ::
          {:ok, Ecto.UUID.t()} | :no_match | :ambiguous | :not_credit_card_batch
  def match_batch(transactions) when is_list(transactions) do
    case credit_card_category() do
      nil ->
        :not_credit_card_batch

      category ->
        transactions
        |> filter_credit_card_orphans()
        |> Enum.group_by(& &1.account_id)
        |> Map.values()
        |> Enum.map(&do_match_batch(&1, category))
        |> summarize_batch_results()
    end
  end

  defp summarize_batch_results([]), do: :not_credit_card_batch
  defp summarize_batch_results([result | _]), do: result

  defp do_match_batch(batch, category) do
    [%{account_id: account_id} | _] = batch
    total = Enum.reduce(batch, Decimal.new(0), &Decimal.add(&2, &1.amount))
    target_amount = Decimal.negate(total)
    latest_date = batch |> Enum.map(& &1.date) |> Enum.max(Date)
    min_date = Date.add(latest_date, -@tolerance_days)
    max_date = Date.add(latest_date, @tolerance_days)

    candidates =
      candidate_payments(category, target_amount, account_id, min_date, max_date)

    case pick_unambiguous_candidate(candidates, latest_date) do
      {:ok, parent} -> link_batch(batch, parent.id)
      :tie -> :ambiguous
      :none -> :no_match
    end
  end

  defp candidate_payments(category, target_amount, exclude_account_id, min_date, max_date) do
    from(t in Transaction,
      where: t.category_id == ^category.id,
      where: t.amount == ^target_amount,
      where: t.account_id != ^exclude_account_id,
      where: t.date >= ^min_date and t.date <= ^max_date,
      where: t.id not in subquery(linked_parent_ids_query())
    )
    |> Repo.all()
  end

  # IDs of every transaction that already has at least one child — used to
  # exclude payments that already have a (possibly different) batch linked.
  defp linked_parent_ids_query do
    from(c in Transaction,
      where: not is_nil(c.parent_transaction_id),
      distinct: true,
      select: c.parent_transaction_id
    )
  end

  defp pick_unambiguous_candidate([], _latest_date), do: :none

  defp pick_unambiguous_candidate(candidates, latest_date) do
    [{best_diff, best} | rest] =
      candidates
      |> Enum.map(&{abs(Date.diff(&1.date, latest_date)), &1})
      |> Enum.sort_by(&elem(&1, 0))

    if Enum.any?(rest, fn {diff, _} -> diff == best_diff end) do
      :tie
    else
      {:ok, best}
    end
  end

  defp link_batch(batch, parent_id) do
    ids = Enum.map(batch, & &1.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Transaction, where: t.id in ^ids)
    |> Repo.update_all(set: [parent_transaction_id: parent_id, updated_at: now])

    {:ok, parent_id}
  end

  defp filter_credit_card_orphans(transactions) do
    account_ids = transactions |> Enum.map(& &1.account_id) |> Enum.uniq()
    credit_card_ids = MapSet.new(credit_card_account_ids(account_ids))

    Enum.filter(transactions, fn t ->
      MapSet.member?(credit_card_ids, t.account_id) and is_nil(t.parent_transaction_id)
    end)
  end

  defp credit_card_account_ids(account_ids) do
    from(a in Account, where: a.id in ^account_ids and a.is_credit_card == true, select: a.id)
    |> Repo.all()
  end

  defp credit_card_category, do: Categories.get_category_by_slug("cartao-de-credito")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions/credit_card_matcher_test.exs`
Expected: PASS (8 tests, 0 failures).

- [ ] **Step 5: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/transactions/credit_card_matcher.ex test/cash_lens/transactions/credit_card_matcher_test.exs
git commit -m "feat(transactions): add CreditCardMatcher.match_batch/1"
```

---

### Task 4: `CreditCardMatcher.match_payment/2`

**Spec section:** 4 (reverse direction: payment categorized → find orphan batch).

**Files:**
- Modify: `lib/cash_lens/transactions/credit_card_matcher.ex`
- Test: `test/cash_lens/transactions/credit_card_matcher_test.exs`

**Interfaces:**
- Consumes: same as Task 3, plus `Transaction.inserted_at` (`utc_datetime`, second precision — shared across one `Ingestor` import call, see `lib/cash_lens/parsers/ingestor.ex:195` `prepare_entries/2`).
- Produces: `CreditCardMatcher.match_payment(Transaction.t(), Ecto.UUID.t() | nil) :: {:ok, non_neg_integer()} | :no_match | :multiple_orphan_batches | :not_credit_card_category`. The second argument is an optional credit-card-account hint: callers that know which card the payment is for (e.g. `TransferRuleApplier`, via the rule's `destination_account_id`) pass it to scope the search to that one account; callers that don't (manual category edits) pass `nil` and the search spans every credit-card account.

- [ ] **Step 1: Write the failing tests**

Append to `test/cash_lens/transactions/credit_card_matcher_test.exs`:

```elixir
  describe "match_payment/2" do
    test "links the single pending orphan batch when its sum matches" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      p2 = purchase(card, "-70.00", ~D[2026-03-03])
      pay = payment(checking, category, "-100.00", ~D[2026-03-05])

      assert {:ok, 2} = CreditCardMatcher.match_payment(pay)
      assert Repo.get!(Transaction, p1.id).parent_transaction_id == pay.id
      assert Repo.get!(Transaction, p2.id).parent_transaction_id == pay.id
    end

    test "returns :no_match when the single orphan batch's sum does not match" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      purchase(card, "-30.00", ~D[2026-03-01])
      pay = payment(checking, category, "-999.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_payment(pay) == :no_match
    end

    test "refuses auto-match when there are two distinct pending orphan batches" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()

      may_p1 = purchase(card, "-100.00", ~D[2026-04-01])
      backdate(may_p1, ~U[2026-04-02 10:00:00Z])

      jun_p1 = purchase(card, "-100.00", ~D[2026-05-01])
      backdate(jun_p1, ~U[2026-05-02 10:00:00Z])

      pay = payment(checking, category, "-100.00", ~D[2026-05-05])

      assert CreditCardMatcher.match_payment(pay) == :multiple_orphan_batches
      refute Repo.get!(Transaction, may_p1.id).parent_transaction_id
      refute Repo.get!(Transaction, jun_p1.id).parent_transaction_id
    end

    test "scopes the search to the given credit-card account hint" do
      category = credit_card_category()
      card_a = card_account()
      card_b = card_account()
      checking = checking_account()

      purchase(card_a, "-50.00", ~D[2026-03-01])
      p_b = purchase(card_b, "-50.00", ~D[2026-03-01])
      pay = payment(checking, category, "-50.00", ~D[2026-03-05])

      assert {:ok, 1} = CreditCardMatcher.match_payment(pay, card_b.id)
      assert Repo.get!(Transaction, p_b.id).parent_transaction_id == pay.id
    end

    test "returns :not_credit_card_category when the payment's category is not Cartão de Crédito" do
      checking = checking_account()
      other_category = category_fixture(%{name: "Mercado", slug: "mercado"})
      pay = payment(checking, other_category, "-100.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_payment(pay) == :not_credit_card_category
    end

    test "returns :no_match when there are no orphan batches at all" do
      category = credit_card_category()
      checking = checking_account()
      pay = payment(checking, category, "-100.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_payment(pay) == :no_match
    end
  end

  defp backdate(%Transaction{id: id}, inserted_at) do
    {1, _} =
      from(t in Transaction, where: t.id == ^id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

    :ok
  end
```

Add `import Ecto.Query` near the top of the test module (next to the existing `import`/`alias` lines) since `backdate/2` uses `from/2`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions/credit_card_matcher_test.exs`
Expected: FAIL — `CreditCardMatcher.match_payment/1` and `/2` undefined.

- [ ] **Step 3: Implement `match_payment/2`**

Append to `lib/cash_lens/transactions/credit_card_matcher.ex`, before the final `end`:

```elixir
  @doc """
  Tries to link a transaction that was just categorized as "Cartão de
  Crédito" to its corresponding orphan batch of credit-card purchases.

  `credit_card_account_id` narrows the search to one card account when the
  caller knows it (e.g. a `TransferRule`'s destination); pass `nil` to
  search across every credit-card account.
  """
  @spec match_payment(Transaction.t(), Ecto.UUID.t() | nil) ::
          {:ok, non_neg_integer()} | :no_match | :multiple_orphan_batches | :not_credit_card_category
  def match_payment(%Transaction{} = payment, credit_card_account_id \\ nil) do
    case credit_card_category() do
      nil ->
        :not_credit_card_category

      %{id: category_id} when payment.category_id != category_id ->
        :not_credit_card_category

      _category ->
        account_ids =
          if credit_card_account_id,
            do: [credit_card_account_id],
            else: all_credit_card_account_ids()

        account_ids
        |> orphan_batches()
        |> do_match_payment(payment)
    end
  end

  defp do_match_payment([], _payment), do: :no_match

  defp do_match_payment([batch], payment) do
    if batch_matches_payment?(batch, payment) do
      link_batch_and_count(batch, payment)
    else
      :no_match
    end
  end

  defp do_match_payment(_batches, _payment), do: :multiple_orphan_batches

  defp batch_matches_payment?(batch, payment) do
    total = Enum.reduce(batch, Decimal.new(0), &Decimal.add(&2, &1.amount))
    target = Decimal.negate(total)
    latest_date = batch |> Enum.map(& &1.date) |> Enum.max(Date)

    Decimal.equal?(target, payment.amount) and
      abs(Date.diff(latest_date, payment.date)) <= @tolerance_days
  end

  defp link_batch_and_count(batch, payment) do
    ids = Enum.map(batch, & &1.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(t in Transaction, where: t.id in ^ids)
      |> Repo.update_all(set: [parent_transaction_id: payment.id, updated_at: now])

    {:ok, count}
  end

  defp orphan_batches(account_ids) do
    from(t in Transaction,
      where: t.account_id in ^account_ids,
      where: is_nil(t.parent_transaction_id)
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.account_id, &1.inserted_at})
    |> Map.values()
  end

  defp all_credit_card_account_ids do
    from(a in Account, where: a.is_credit_card == true, select: a.id)
    |> Repo.all()
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions/credit_card_matcher_test.exs`
Expected: PASS (14 tests total, 0 failures).

- [ ] **Step 5: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/transactions/credit_card_matcher.ex test/cash_lens/transactions/credit_card_matcher_test.exs
git commit -m "feat(transactions): add CreditCardMatcher.match_payment/2"
```

---

### Task 5: Wire `CreditCardMatcher.match_batch/1` into the import pipeline

**Spec section:** 4 (last bullet — "Chamado no pipeline de import").

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex`
- Test: `test/cash_lens/parsers/ingestor_test.exs`

**Interfaces:**
- Consumes: `CreditCardMatcher.match_batch/1` (Task 3).
- Produces: no new public function — `Ingestor.import_file/3` now also attempts credit-card batch linking as a side effect.

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens/parsers/ingestor_test.exs`, inside `describe "import_file/2"` (reuse its `import CashLens.AccountsFixtures` and add the other fixture imports at the top of the block):

```elixir
    test "links an imported credit-card batch to an existing Cartão de Crédito payment" do
      import CashLens.CategoriesFixtures
      import CashLens.TransactionsFixtures

      category = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true, parser_type: "bb_csv"})

      # bb_sample.csv totals -120.50 across its 3 rows (see other tests in this file).
      _payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: category.id,
          amount: "-120.50",
          date: ~D[2026-01-05],
          description: "pagamento fatura"
        })

      assert {:ok, %{imported: 3}} = Ingestor.import_file(card, @bb_sample)

      linked_count =
        CashLens.Repo.aggregate(
          from(t in CashLens.Transactions.Transaction,
            where: t.account_id == ^card.id and not is_nil(t.parent_transaction_id)
          ),
          :count
        )

      assert linked_count == 3
    end
```

Add `import Ecto.Query` to the top of the test module if not already present (it is not — add it next to `alias CashLens.Parsers.Ingestor`).

First confirm the actual sum of `test/support/fixtures/files/bb_sample.csv` matches `-120.50`:

Run: `mix run -e 'IO.inspect(CashLens.Parsers.Ingestor.parse(File.read!("test/support/fixtures/files/bb_sample.csv"), "bb_csv") |> Enum.map(& &1.amount) |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1)))'`

Use whatever total that prints as the `amount` in the test above (replace `-120.50` if different) — do not guess, read the actual output.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: FAIL — `linked_count == 0`, not `3` (matcher isn't wired in yet).

- [ ] **Step 3: Wire the matcher into `process_entries/3`**

In `lib/cash_lens/parsers/ingestor.ex`, add the alias near the top:

```elixir
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction
```

In `process_entries/3`, add the call right after `mirror_transactions` is computed (before the `TransferMatcher.match_transfers/1` call):

```elixir
    # 3. Apply transfer rules for newly inserted transactions, creating mirrors as needed
    mirror_transactions = TransferRuleApplier.apply_rules(inserted_transactions)

    # 3b. Try to link a freshly-imported credit-card invoice batch to an
    # existing "Cartão de Crédito" payment transaction.
    CreditCardMatcher.match_batch(inserted_transactions)

    # 4. Run TransferMatcher for new transactions (including mirrors) in batch
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full Ingestor test file to check for regressions**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: all tests pass (no behavior change for non-credit-card imports, since `match_batch/1` returns `:not_credit_card_batch` early for them).

- [ ] **Step 6: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/cash_lens/parsers/ingestor.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "feat(parsers): link imported credit-card batches during ingest"
```

---

### Task 6: `TransferRuleApplier` — credit-card destination branch

**Spec section:** 3.

**Files:**
- Modify: `lib/cash_lens/transactions/transfer_rule_applier.ex`
- Test: `test/cash_lens/transactions/transfer_rule_applier_test.exs`

**Interfaces:**
- Consumes: `CreditCardMatcher.match_payment/2` (Task 4), `Categories.get_category_by_slug/1`.
- Produces: `TransferRuleApplier.apply_rules/1` and `maybe_apply_rule/1` keep their existing signatures and return type (`[Transaction.t()]`, the list of newly-created mirrors); for rules whose destination is a credit-card account they now always return `[]` (no mirror is ever created for that branch).

- [ ] **Step 1: Write the failing tests**

Add to `test/cash_lens/transactions/transfer_rule_applier_test.exs`, inside `describe "apply_rules/1"`:

```elixir
    test "categorizes as Cartão de Crédito and creates no mirror when destination is a credit-card account" do
      cc_category = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
      source = account_fixture()
      card = account_fixture(%{is_credit_card: true})
      create_rule(source.id, card.id, ["pagamento fatura"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Pagamento Fatura Cartão",
          amount: "-500.00",
          date: ~D[2026-01-15]
        })

      mirrors = TransferRuleApplier.apply_rules([tx])

      assert mirrors == []
      updated_tx = Repo.get!(Transaction, tx.id)
      assert updated_tx.category_id == cc_category.id
      assert is_nil(updated_tx.transfer_key)
      assert Repo.all(from t in Transaction, where: t.account_id == ^card.id) == []
    end

    test "credit-card branch tries to link an existing orphan batch on the destination card" do
      cc_category = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
      source = account_fixture()
      card = account_fixture(%{is_credit_card: true})
      create_rule(source.id, card.id, ["pagamento fatura"])

      purchase =
        insert_raw_transaction(%{
          account_id: card.id,
          description: "Uber",
          amount: "-500.00",
          date: ~D[2026-01-10]
        })

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Pagamento Fatura Cartão",
          amount: "-500.00",
          date: ~D[2026-01-15]
        })

      TransferRuleApplier.apply_rules([tx])

      updated_tx = Repo.get!(Transaction, tx.id)
      updated_purchase = Repo.get!(Transaction, purchase.id)
      assert updated_tx.category_id == cc_category.id
      assert updated_purchase.parent_transaction_id == updated_tx.id
    end

    test "ignores create_mirror: true for credit-card destinations" do
      category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
      source = account_fixture()
      card = account_fixture(%{is_credit_card: true})

      {:ok, _rule} =
        Repo.insert(%TransferRule{
          description_patterns: ["pagamento fatura"],
          source_account_id: source.id,
          destination_account_id: card.id,
          create_mirror: true
        })

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Pagamento Fatura Cartão",
          amount: "-500.00",
          date: ~D[2026-01-15]
        })

      mirrors = TransferRuleApplier.apply_rules([tx])
      assert mirrors == []
      assert Repo.all(from t in Transaction, where: t.account_id == ^card.id) == []
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions/transfer_rule_applier_test.exs`
Expected: FAIL — `updated_tx.category_id` still equals the old "transfer" category (or a mirror still gets created), since the credit-card branch doesn't exist yet.

- [ ] **Step 3: Implement the branch**

In `lib/cash_lens/transactions/transfer_rule_applier.ex`:

Add the alias:

```elixir
  alias CashLens.Repo
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule
```

Change `load_rules_by_source/0` to preload the destination account:

```elixir
  defp load_rules_by_source do
    TransferRule
    |> Repo.all()
    |> Repo.preload(:destination_account)
    |> Enum.group_by(& &1.source_account_id)
  end
```

Replace `apply_rules_to_transaction/3` with a version that branches on the destination account, and rename `set_transfer_category/2` to the more general `set_category/2` (update its one existing call site too):

```elixir
  defp apply_rules_to_transaction(tx, rules_by_source, transfer_category) do
    account_rules = Map.get(rules_by_source, tx.account_id, [])
    description_lower = String.downcase(tx.description || "")

    matched_rule =
      Enum.find(account_rules, fn rule ->
        Enum.any?(rule.description_patterns, fn pattern ->
          String.contains?(description_lower, String.downcase(pattern))
        end)
      end)

    case matched_rule do
      nil -> []
      rule -> apply_matched_rule(tx, rule, transfer_category)
    end
  end

  defp apply_matched_rule(tx, %{destination_account: %{is_credit_card: true}} = rule, _transfer_category) do
    apply_credit_card_rule(tx, rule)
  end

  defp apply_matched_rule(tx, rule, transfer_category) do
    set_category(tx, transfer_category)

    if rule.create_mirror do
      maybe_create_mirror(tx, rule, transfer_category)
    else
      []
    end
  end

  defp apply_credit_card_rule(tx, rule) do
    case Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        Logger.warning(
          "TransferRuleApplier: 'cartao-de-credito' category not found; skipping rule application."
        )

        []

      category ->
        set_category(tx, category)
        CreditCardMatcher.match_payment(%{tx | category_id: category.id}, rule.destination_account_id)
        []
    end
  end

  defp set_category(tx, category) do
    if tx.category_id != category.id do
      from(t in Transaction, where: t.id == ^tx.id)
      |> Repo.update_all(
        set: [
          category_id: category.id,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
    end
  end
```

Delete the old `set_transfer_category/2` function (it's now `set_category/2`, used by both branches).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions/transfer_rule_applier_test.exs`
Expected: PASS — including all the pre-existing tests in the file (the non-credit-card branch is functionally unchanged, just renamed internally).

- [ ] **Step 5: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/transactions/transfer_rule_applier.ex test/cash_lens/transactions/transfer_rule_applier_test.exs
git commit -m "feat(transactions): categorize credit-card transfer rules as Cartão de Crédito"
```

---

### Task 7: Category-change guard in `CashLens.Transactions` + `reapply_transfer_rules/0`

**Spec section:** 4 (guard + "Reaplicar Regras" bullets).

**Files:**
- Modify: `lib/cash_lens/transactions.ex`
- Test: `test/cash_lens/transactions_test.exs` (create if it does not already cover these functions — check first with `grep -n "update_transaction_category\|reapply_transfer_rules" test/cash_lens/transactions_test.exs`)

**Interfaces:**
- Consumes: `CreditCardMatcher.match_payment/1` (Task 4, called with no account hint here since none of these call sites know which card the payment is for).
- Produces: `update_transaction_category/2`, `create_transaction/1`, and `update_transaction/2` keep their existing signatures; they now additionally call `CreditCardMatcher.match_payment/1` exactly when the transaction's resulting category is "Cartão de Crédito". `reapply_transfer_rules/0` keeps its `:ok` return and additionally retries `CreditCardMatcher.match_payment/1` for "Cartão de Crédito" transactions that still have no children.

- [ ] **Step 1: Check existing test coverage**

Run: `grep -n "describe \"update_transaction_category\|describe \"create_transaction\|describe \"update_transaction\|describe \"reapply_transfer_rules" test/cash_lens/transactions_test.exs`

If the file/describes don't exist, create `test/cash_lens/transactions_test.exs` following the existing fixture-import pattern (see `test/cash_lens/transactions/transfer_rule_applier_test.exs` for the imports). If they do exist, add the new tests inside the matching `describe` blocks.

- [ ] **Step 2: Write the failing tests**

```elixir
defmodule CashLens.TransactionsTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  defp cc_category, do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
  defp other_category, do: category_fixture(%{name: "Mercado", slug: "mercado"})

  describe "update_transaction_category/2 — credit card matching guard" do
    test "links a pending orphan batch when the category becomes Cartão de Crédito" do
      category = cc_category()
      card = account_fixture(%{is_credit_card: true})
      checking = account_fixture(%{is_credit_card: false})

      purchase =
        transaction_fixture(%{account_id: card.id, amount: "-50.00", date: ~D[2026-02-01]})

      payment =
        transaction_fixture(%{account_id: checking.id, amount: "-50.00", date: ~D[2026-02-05]})

      {:ok, _} = Transactions.update_transaction_category(payment.id, category.id)

      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
    end

    test "does not call the matcher when the new category is not Cartão de Crédito" do
      category = other_category()
      checking = account_fixture(%{is_credit_card: false})
      tx = transaction_fixture(%{account_id: checking.id, amount: "-50.00", date: ~D[2026-02-05]})

      assert {:ok, updated} = Transactions.update_transaction_category(tx.id, category.id)
      assert updated.category_id == category.id
    end
  end

  describe "reapply_transfer_rules/0 — credit card retry" do
    test "retries matching for Cartão de Crédito payments still without children" do
      category = cc_category()
      card = account_fixture(%{is_credit_card: true})
      checking = account_fixture(%{is_credit_card: false})

      purchase =
        transaction_fixture(%{account_id: card.id, amount: "-50.00", date: ~D[2026-02-01]})

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: category.id,
          amount: "-50.00",
          date: ~D[2026-02-05]
        })

      assert is_nil(Repo.get!(Transaction, purchase.id).parent_transaction_id)

      Transactions.reapply_transfer_rules()

      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: FAIL — `purchase.parent_transaction_id` stays `nil` after both `update_transaction_category/2` and `reapply_transfer_rules/0`.

- [ ] **Step 4: Add the alias and the guard helper**

In `lib/cash_lens/transactions.ex`, add the alias next to the existing ones:

```elixir
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.BulkIgnorePattern
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.RejectedReimbursementPair
```

Add the shared guard helper near `get_transfer_category_id/0` (around line 929):

```elixir
  defp get_transfer_category_id do
    case CashLens.Categories.get_category_by_slug("transfer") do
      nil -> nil
      category -> category.id
    end
  end

  defp get_credit_card_category_id do
    case CashLens.Categories.get_category_by_slug("cartao-de-credito") do
      nil -> nil
      category -> category.id
    end
  end

  defp maybe_match_credit_card_payment(%Transaction{} = tx) do
    cc_id = get_credit_card_category_id()

    if cc_id && tx.category_id == cc_id do
      CreditCardMatcher.match_payment(tx)
    end

    :ok
  end
```

- [ ] **Step 5: Hook it into `update_transaction_category/2`**

```elixir
  def update_transaction_category(id, category_id) do
    transaction = get_transaction!(id)

    extra =
      case category_id && Repo.get(Category, category_id) do
        %Category{default_reimbursable: true} when is_nil(transaction.reimbursement_status) ->
          %{reimbursement_status: "pending"}

        _ ->
          %{}
      end

    transaction
    |> Ecto.Changeset.cast(Map.merge(%{category_id: category_id}, extra), [
      :category_id,
      :reimbursement_status
    ])
    |> Ecto.Changeset.foreign_key_constraint(:category_id)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        maybe_match_credit_card_payment(updated)
        CashLens.Accounting.rebuild_account_balances(updated.account_id)
        {:ok, updated}

      error ->
        error
    end
  end
```

- [ ] **Step 6: Hook it into `create_transaction/1` and `update_transaction/2`**

In `create_transaction/1`, inside the `{:ok, transaction} ->` branch, right after the existing `twin_account_id = ...` block and before "Rebuild balances for the original account":

```elixir
        maybe_match_credit_card_payment(transaction)

        # Rebuild balances for the original account
        CashLens.Accounting.rebuild_account_balances(transaction.account_id)
```

In `update_transaction/2`, inside the `{:ok, updated_transaction} ->` branch, right before `CashLens.Accounting.rebuild_account_balances(updated_transaction.account_id)`:

```elixir
      {:ok, updated_transaction} ->
        maybe_match_credit_card_payment(updated_transaction)
        CashLens.Accounting.rebuild_account_balances(updated_transaction.account_id)
```

- [ ] **Step 7: Extend `reapply_transfer_rules/0`**

```elixir
  def reapply_transfer_rules do
    unmatched =
      Repo.all(
        from t in Transaction,
          where: is_nil(t.transfer_key)
      )

    Enum.each(unmatched, &TransferRuleApplier.maybe_apply_rule/1)

    unmatched_after =
      Repo.all(
        from t in Transaction,
          where: is_nil(t.transfer_key)
      )

    TransferMatcher.match_transfers(unmatched_after)

    retry_credit_card_matching()

    # Rebuild balances for all active accounts after applying rules
    Enum.each(CashLens.Accounts.list_active_accounts(), fn account ->
      CashLens.Accounting.rebuild_account_balances(account.id)
    end)

    :ok
  end

  defp retry_credit_card_matching do
    case get_credit_card_category_id() do
      nil ->
        :ok

      cc_id ->
        linked_parent_ids =
          from(c in Transaction, where: not is_nil(c.parent_transaction_id), select: c.parent_transaction_id, distinct: true)

        from(t in Transaction,
          where: t.category_id == ^cc_id,
          where: t.id not in subquery(linked_parent_ids)
        )
        |> Repo.all()
        |> Enum.each(&CreditCardMatcher.match_payment/1)
    end
  end
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: PASS.

- [ ] **Step 9: Run the broader transactions test suite for regressions**

Run: `mix test test/cash_lens/transactions_test.exs test/cash_lens/transactions/`
Expected: all pass.

- [ ] **Step 10: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 11: Commit**

```bash
git add lib/cash_lens/transactions.ex test/cash_lens/transactions_test.exs
git commit -m "feat(transactions): trigger CreditCardMatcher on manual category changes and reapply"
```

---

### Task 8: Exclude "Cartão de Crédito" from financial totals (avoid double counting)

**Spec section:** 8.

**Files:**
- Modify: `lib/cash_lens/transactions.ex`
- Test: `test/cash_lens/transactions_test.exs`

**Interfaces:**
- Consumes: none new.
- Produces: `get_filtered_summary/1`, `get_monthly_summary/2`, `get_historical_summary/1` keep their existing signatures and return shapes; they now also exclude `category.slug == "cartao-de-credito"` from income/expense totals, exactly like `"transfer"`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cash_lens/transactions_test.exs`:

```elixir
  describe "totals exclude Cartão de Crédito (no double counting)" do
    test "get_filtered_summary/1 excludes the payment but counts the itemized purchase" do
      cc = cc_category()
      market = other_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      summary = Transactions.get_filtered_summary(%{})
      assert Decimal.equal?(summary.expenses, Decimal.new("500.00"))
    end

    test "get_monthly_summary/2 excludes Cartão de Crédito payments" do
      cc = cc_category()
      checking = account_fixture(%{is_credit_card: false})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      summary = Transactions.get_monthly_summary(~D[2026-02-15])
      assert Decimal.equal?(summary.expenses, Decimal.new("0"))
    end

    test "get_historical_summary/1 excludes Cartão de Crédito payments" do
      cc = cc_category()
      checking = account_fixture(%{is_credit_card: false})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      [row] = Transactions.get_historical_summary()
      assert Decimal.equal?(row.expenses, Decimal.new("0"))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: FAIL — all three assert `500.00`/non-zero where `0` (or `0`/`500` swapped) is expected, because the new category isn't excluded yet.

- [ ] **Step 3: Update `exclude_transfer_category/1`**

```elixir
  # Excludes transactions categorized as transfers or credit-card payments
  # from income/expense aggregates (the itemized purchases still count, just
  # not the lump-sum payment — see spec section 8).
  defp exclude_transfer_category(query) do
    excluded_ids =
      ["transfer", "cartao-de-credito"]
      |> Enum.map(&Repo.one(from(c in Category, where: c.slug == ^&1, select: c.id)))
      |> Enum.reject(&is_nil/1)

    if excluded_ids == [] do
      query
    else
      where(query, [t], is_nil(t.category_id) or t.category_id not in ^excluded_ids)
    end
  end
```

- [ ] **Step 4: Update `build_summary_base_query/1`**

```elixir
  defp build_summary_base_query(query) do
    from t in query,
      left_join: c in assoc(t, :category),
      # Transfers and credit-card payments move money between the user's own
      # "buckets" (another account, or a not-yet-itemized bill), so they
      # never count as income/expense — paired/itemized or not.
      where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer", "cartao-de-credito"],
      where: is_nil(t.reimbursement_link_key)
  end
```

- [ ] **Step 5: Update `get_historical_summary/1`**

```elixir
    query =
      from t in Transaction,
        left_join: c in assoc(t, :category),
        where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer", "cartao-de-credito"],
        where: is_nil(t.reimbursement_link_key),
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: PASS.

- [ ] **Step 7: Regression-check the full transactions test suite**

Run: `mix test test/cash_lens/transactions_test.exs test/cash_lens/transactions/ lib/cash_lens_web/controllers/page_controller_test.exs`

If `page_controller_test.exs` doesn't exist under that exact path, find it:

Run: `find test -iname "page_controller_test.exs"`

and run that path instead. Expected: all pass — `PageController.home/2` consumes `get_monthly_summary/0` and `get_historical_summary/1`, so this is the place a regression would show up.

- [ ] **Step 8: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add lib/cash_lens/transactions.ex test/cash_lens/transactions_test.exs
git commit -m "fix(transactions): exclude Cartão de Crédito from income/expense totals"
```

---

### Task 9: "No children" anti-join in category-breakdown queries

**Spec section:** 7.

**Files:**
- Modify: `lib/cash_lens/transactions.ex`
- Test: `test/cash_lens/transactions_test.exs`

**Interfaces:**
- Consumes: none new.
- Produces: `get_month_category_breakdown/2` and `query_historical_category_totals/0` (used by `get_historical_category_summary/1`) keep their existing signatures/return shapes; both now exclude any transaction that has at least one child (`parent_transaction_id` pointed at it by another row).

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "category breakdown excludes transactions with children" do
    test "get_month_category_breakdown/2 hides the parent and shows the children's own categories" do
      cc = cc_category()
      uber_cat = category_fixture(%{name: "Transporte", slug: "transporte"})
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: cc.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      child =
        transaction_fixture(%{
          account_id: card.id,
          category_id: uber_cat.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      {1, _} =
        from(t in Transaction, where: t.id == ^child.id)
        |> Repo.update_all(set: [parent_transaction_id: payment.id])

      breakdown = Transactions.get_month_category_breakdown(2026, 2)

      refute Enum.any?(breakdown, &(&1.category_id == cc.id))
      assert Enum.any?(breakdown, &(&1.category_id == uber_cat.id))
    end

    test "a Cartão de Crédito transaction with no children still appears in the breakdown" do
      cc = cc_category()
      checking = account_fixture(%{is_credit_card: false})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-100.00",
        date: ~D[2026-02-10]
      })

      breakdown = Transactions.get_month_category_breakdown(2026, 2)
      assert Enum.any?(breakdown, &(&1.category_id == cc.id))
    end

    test "get_historical_category_summary/1 excludes parents with children" do
      cc = cc_category()
      uber_cat = category_fixture(%{name: "Transporte", slug: "transporte"})
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: cc.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      child =
        transaction_fixture(%{
          account_id: card.id,
          category_id: uber_cat.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      {1, _} =
        from(t in Transaction, where: t.id == ^child.id)
        |> Repo.update_all(set: [parent_transaction_id: payment.id])

      [month] = Transactions.get_historical_category_summary(limit: 1)
      category_ids = Enum.map(month.categories, & &1.category_id)

      refute cc.id in category_ids
      assert uber_cat.id in category_ids
    end
  end
```

(Add `import Ecto.Query` at the top of `test/cash_lens/transactions_test.exs` if it isn't already imported via `use CashLens.DataCase` — check the file; `DataCase` typically does `import Ecto.Query` for you, confirm by grepping `test/support/data_case.ex`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: FAIL — the first and third tests find the parent's `cc.id` still present in the breakdown.

- [ ] **Step 3: Add the shared "has no children" filter and apply it**

Add a private helper near `query_historical_category_totals/0`:

```elixir
  # Transactions that are themselves a parent (another transaction points its
  # parent_transaction_id at them) are excluded from category-spend
  # breakdowns: their amount is the lump sum of their children, who already
  # carry the real categories. See spec section 7.
  defp exclude_transactions_with_children(query) do
    linked_parent_ids =
      from(c in Transaction,
        where: not is_nil(c.parent_transaction_id),
        distinct: true,
        select: c.parent_transaction_id
      )

    where(query, [t], t.id not in subquery(linked_parent_ids))
  end
```

Apply it in `get_month_category_breakdown/2`'s `categorized` query, adding the call right after the `where: c.slug not in [...]` line:

```elixir
    categorized =
      from(t in Transaction,
        join: c in assoc(t, :category),
        left_join: p in assoc(c, :parent),
        left_join: g in assoc(p, :parent),
        where: t.date >= ^first and t.date <= ^last,
        where: t.amount < 0,
        where: c.slug not in ["initial_value", "transfer"],
        group_by: [
          fragment("COALESCE(?, ?, ?)", g.name, p.name, c.name),
          fragment("COALESCE(?, ?, ?)", g.id, p.id, c.id),
          fragment("COALESCE(?, ?, ?)", g.type, p.type, c.type)
        ],
        select: %{
          name: fragment("COALESCE(?, ?, ?)", g.name, p.name, c.name),
          category_id: type(fragment("COALESCE(?, ?, ?)", g.id, p.id, c.id), :binary_id),
          type: fragment("COALESCE(?, ?, ?)", g.type, p.type, c.type),
          total: sum(t.amount)
        },
        having: sum(t.amount) < 0,
        order_by: [asc: sum(t.amount)]
      )
      |> exclude_transactions_with_children()
      |> Repo.all()
      |> Enum.map(fn row -> %{row | total: Decimal.abs(row.total)} end)
```

Apply it in `query_historical_category_totals/0`:

```elixir
  defp query_historical_category_totals do
    from(t in Transaction,
      join: c in assoc(t, :category),
      left_join: p in assoc(c, :parent),
      where: t.amount < 0,
      where: c.slug not in ["initial_value", "transfer"],
      where: is_nil(t.reimbursement_link_key),
      where: t.reimbursement_status != "pending" or is_nil(t.reimbursement_status),
      select: %{
        year: fragment("EXTRACT(YEAR FROM ?)", t.date),
        month: fragment("EXTRACT(MONTH FROM ?)", t.date),
        category_name: c.name,
        parent_name: p.name,
        type: c.type,
        total: t.amount
      }
    )
    |> exclude_transactions_with_children()
  end
```

(Keep the existing `from t in Transaction, ... select: %{...}` body — just wrap it in `from(...)` parens as shown above if it isn't already, and pipe it through the new helper instead of returning the bare `from` expression directly.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: PASS.

- [ ] **Step 5: Regression-check existing category breakdown tests**

Run: `mix test test/cash_lens/transactions_test.exs test/cash_lens/transactions/ lib/cash_lens_web/`

Find the actual existing test file(s) covering `get_month_category_breakdown/2` / `get_historical_category_summary/1` first:

Run: `grep -rln "get_month_category_breakdown\|get_historical_category_summary" test/`

and include those paths explicitly in the run above. Expected: all pass.

- [ ] **Step 6: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/cash_lens/transactions.ex test/cash_lens/transactions_test.exs
git commit -m "fix(transactions): exclude transactions with children from category breakdowns"
```

---

### Task 10: Query/link functions for the `/credit_card_links` screen

**Spec section:** 6.

**Files:**
- Modify: `lib/cash_lens/transactions.ex`
- Test: `test/cash_lens/transactions_test.exs`

**Interfaces:**
- Consumes: none new.
- Produces (all in `CashLens.Transactions`):
  - `list_credit_card_orphan_batches/0 :: [%{account_id: id, account: Account.t(), inserted_at: DateTime.t(), transactions: [Transaction.t()], total: Decimal.t()}]`
  - `list_credit_card_link_suggestions/0 :: [{Transaction.t(), map()}]` — `{payment, batch}` tuples, `batch` shaped like one entry of `list_credit_card_orphan_batches/0`.
  - `list_credit_card_divergent_links/0 :: [%{parent: Transaction.t(), children: [Transaction.t()], children_total: Decimal.t()}]`
  - `list_credit_card_linked/0 :: [%{parent: Transaction.t(), children: [Transaction.t()], children_total: Decimal.t()}]`
  - `link_credit_card_batch([Ecto.UUID.t()], Ecto.UUID.t()) :: :ok`
  - `unlink_credit_card_children(Ecto.UUID.t()) :: :ok`

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "credit card link screen queries" do
    setup do
      cc = cc_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})
      %{cc: cc, checking: checking, card: card}
    end

    test "list_credit_card_orphan_batches/0 groups orphan purchases by import batch", %{card: card} do
      p1 = transaction_fixture(%{account_id: card.id, amount: "-30.00", date: ~D[2026-03-01]})
      p2 = transaction_fixture(%{account_id: card.id, amount: "-70.00", date: ~D[2026-03-02]})

      {2, _} =
        from(t in Transaction, where: t.id in [^p1.id, ^p2.id])
        |> Repo.update_all(set: [inserted_at: ~U[2026-03-02 09:00:00Z]])

      [batch] = Transactions.list_credit_card_orphan_batches()
      assert batch.account_id == card.id
      assert Decimal.equal?(batch.total, Decimal.new("-100.00"))
      assert length(batch.transactions) == 2
    end

    test "list_credit_card_link_suggestions/0 finds exact-amount matches regardless of date", %{
      cc: cc,
      checking: checking,
      card: card
    } do
      transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: cc.id,
          amount: "-100.00",
          date: ~D[2026-06-01]
        })

      [{suggested_payment, batch}] = Transactions.list_credit_card_link_suggestions()
      assert suggested_payment.id == payment.id
      assert Decimal.equal?(batch.total, Decimal.new("-100.00"))
    end

    test "list_credit_card_divergent_links/0 and list_credit_card_linked/0 partition by sum match", %{
      cc: cc,
      checking: checking,
      card: card
    } do
      ok_payment =
        transaction_fixture(%{account_id: checking.id, category_id: cc.id, amount: "-100.00", date: ~D[2026-03-05]})

      ok_child =
        transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})

      bad_payment =
        transaction_fixture(%{account_id: checking.id, category_id: cc.id, amount: "-200.00", date: ~D[2026-04-05]})

      bad_child =
        transaction_fixture(%{account_id: card.id, amount: "-150.00", date: ~D[2026-04-01]})

      Transactions.link_credit_card_batch([ok_child.id], ok_payment.id)
      Transactions.link_credit_card_batch([bad_child.id], bad_payment.id)

      linked = Transactions.list_credit_card_linked()
      divergent = Transactions.list_credit_card_divergent_links()

      assert Enum.any?(linked, &(&1.parent.id == ok_payment.id))
      assert Enum.any?(divergent, &(&1.parent.id == bad_payment.id))
      refute Enum.any?(linked, &(&1.parent.id == bad_payment.id))
      refute Enum.any?(divergent, &(&1.parent.id == ok_payment.id))
    end

    test "unlink_credit_card_children/1 clears parent_transaction_id on all children", %{
      cc: cc,
      checking: checking,
      card: card
    } do
      payment =
        transaction_fixture(%{account_id: checking.id, category_id: cc.id, amount: "-100.00", date: ~D[2026-03-05]})

      child = transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})

      Transactions.link_credit_card_batch([child.id], payment.id)
      Transactions.unlink_credit_card_children(payment.id)

      assert is_nil(Repo.get!(Transaction, child.id).parent_transaction_id)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: FAIL — `UndefinedFunctionError` for each new public function.

- [ ] **Step 3: Implement the functions**

Add to `lib/cash_lens/transactions.ex` (near the other `list_*transfer*` functions, e.g. right before `list_transfer_suggestions/0`):

```elixir
  @doc """
  Groups every still-unlinked credit-card transaction into the import batch
  it arrived in ({account_id, inserted_at} — see `CreditCardMatcher` docs
  for why that pair identifies a batch).
  """
  def list_credit_card_orphan_batches do
    credit_card_ids =
      from(a in CashLens.Accounts.Account, where: a.is_credit_card == true, select: a.id)
      |> Repo.all()

    from(t in Transaction,
      where: t.account_id in ^credit_card_ids,
      where: is_nil(t.parent_transaction_id),
      preload: [:account, :category]
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.account_id, &1.inserted_at})
    |> Enum.map(fn {{account_id, inserted_at}, txs} ->
      %{
        account_id: account_id,
        account: List.first(txs).account,
        inserted_at: inserted_at,
        transactions: Enum.sort_by(txs, & &1.date, Date),
        total: Enum.reduce(txs, Decimal.new(0), &Decimal.add(&2, &1.amount))
      }
    end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Orphan batches whose total exactly matches an unlinked "Cartão de
  Crédito" payment, with no date constraint (wider net than
  `CreditCardMatcher`'s automatic ±5-day match, for one-click manual
  confirmation of cases the automatic matcher declined — ties, multiple
  pending batches, etc).
  """
  def list_credit_card_link_suggestions do
    case CashLens.Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        []

      category ->
        payments = unlinked_credit_card_payments(category)
        batches = list_credit_card_orphan_batches()

        for payment <- payments,
            batch <- batches,
            Decimal.equal?(Decimal.negate(batch.total), payment.amount) do
          {payment, batch}
        end
    end
  end

  defp unlinked_credit_card_payments(category) do
    from(t in Transaction,
      where: t.category_id == ^category.id,
      where: t.id not in subquery(linked_parent_ids_subquery()),
      preload: [:account]
    )
    |> Repo.all()
  end

  defp linked_parent_ids_subquery do
    from(c in Transaction,
      where: not is_nil(c.parent_transaction_id),
      distinct: true,
      select: c.parent_transaction_id
    )
  end

  @doc """
  Linked "Cartão de Crédito" payments whose children's total does NOT match
  the payment amount — the reconciliation alert.
  """
  def list_credit_card_divergent_links do
    "cartao-de-credito"
    |> linked_credit_card_pairs()
    |> Enum.reject(&credit_card_sum_matches?/1)
  end

  @doc """
  Linked "Cartão de Crédito" payments whose children's total matches the
  payment amount.
  """
  def list_credit_card_linked do
    "cartao-de-credito"
    |> linked_credit_card_pairs()
    |> Enum.filter(&credit_card_sum_matches?/1)
  end

  defp credit_card_sum_matches?(%{parent: parent, children_total: total}) do
    Decimal.equal?(Decimal.negate(total), parent.amount)
  end

  defp linked_credit_card_pairs(slug) do
    case CashLens.Categories.get_category_by_slug(slug) do
      nil ->
        []

      category ->
        parents =
          from(t in Transaction,
            where: t.category_id == ^category.id,
            where: t.id in subquery(linked_parent_ids_subquery()),
            preload: [:account]
          )
          |> Repo.all()

        children_by_parent =
          from(c in Transaction, where: not is_nil(c.parent_transaction_id), preload: [:account])
          |> Repo.all()
          |> Enum.group_by(& &1.parent_transaction_id)

        Enum.map(parents, fn parent ->
          children = Map.get(children_by_parent, parent.id, [])
          total = Enum.reduce(children, Decimal.new(0), &Decimal.add(&2, &1.amount))

          %{
            parent: parent,
            children: Enum.sort_by(children, & &1.date, Date),
            children_total: total
          }
        end)
    end
  end

  @doc """
  Assigns `parent_id` as the `parent_transaction_id` of every transaction in
  `transaction_ids` (manual reconciliation on the `/credit_card_links`
  screen).
  """
  def link_credit_card_batch(transaction_ids, parent_id) when is_list(transaction_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Transaction, where: t.id in ^transaction_ids)
    |> Repo.update_all(set: [parent_transaction_id: parent_id, updated_at: now])

    :ok
  end

  @doc """
  Clears `parent_transaction_id` on every child of `parent_id`.
  """
  def unlink_credit_card_children(parent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Transaction, where: t.parent_transaction_id == ^parent_id)
    |> Repo.update_all(set: [parent_transaction_id: nil, updated_at: now])

    :ok
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/transactions_test.exs`
Expected: PASS.

- [ ] **Step 5: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/transactions.ex test/cash_lens/transactions_test.exs
git commit -m "feat(transactions): add query/link functions for credit card reconciliation"
```

---

### Task 11: `/credit_card_links` LiveView screen

**Spec section:** 6.

**Files:**
- Create: `lib/cash_lens_web/live/credit_card_link_live/index.ex`
- Modify: `lib/cash_lens_web/router.ex`
- Modify: `lib/cash_lens_web/components/layouts/app.html.heex`
- Test: `test/cash_lens_web/live/credit_card_link_live/index_test.exs`

**Interfaces:**
- Consumes: `Transactions.list_credit_card_orphan_batches/0`, `list_credit_card_link_suggestions/0`, `list_credit_card_divergent_links/0`, `list_credit_card_linked/0`, `link_credit_card_batch/2`, `unlink_credit_card_children/1` (Task 10).
- Produces: route `GET /credit_card_links` rendering `CashLensWeb.CreditCardLinkLive.Index`.

- [ ] **Step 1: Add the route**

In `lib/cash_lens_web/router.ex`, inside the `live_session :default` block, right after `live "/transfers", TransferLive.Index, :index`:

```elixir
      live "/transfers", TransferLive.Index, :index
      live "/credit_card_links", CreditCardLinkLive.Index, :index
      live "/installments", InstallmentLive.Index, :index
```

- [ ] **Step 2: Add the nav link**

In `lib/cash_lens_web/components/layouts/app.html.heex`, right after the `/transfers` `<li>` (line 40-44):

```heex
          <li>
            <a href="/transfers" class="rounded-lg hover:bg-base-200 transition-all">
              Transferências
            </a>
          </li>
          <li>
            <a href="/credit_card_links" class="rounded-lg hover:bg-base-200 transition-all">
              Cartão de Crédito
            </a>
          </li>
```

- [ ] **Step 3: Write the failing test**

```elixir
# test/cash_lens_web/live/credit_card_link_live/index_test.exs
defmodule CashLensWeb.CreditCardLinkLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  defp cc_category, do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

  test "shows an orphan batch under 'Sem Pai Encontrado'", %{conn: conn} do
    card = account_fixture(%{is_credit_card: true})
    transaction_fixture(%{account_id: card.id, amount: "-30.00", date: ~D[2026-03-01]})

    {:ok, _view, html} = live(conn, ~p"/credit_card_links")
    assert html =~ "Sem Pai Encontrado"
    assert html =~ "-30"
  end

  test "shows a divergent pair under 'Vinculados com Divergência'", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    payment =
      transaction_fixture(%{account_id: checking.id, category_id: cc.id, amount: "-200.00", date: ~D[2026-03-05]})

    child = transaction_fixture(%{account_id: card.id, amount: "-150.00", date: ~D[2026-03-01]})
    Transactions.link_credit_card_batch([child.id], payment.id)

    {:ok, _view, html} = live(conn, ~p"/credit_card_links")
    assert html =~ "Vinculados com Divergência"
  end

  test "confirming a suggestion links the batch", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    purchase = transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})

    payment =
      transaction_fixture(%{account_id: checking.id, category_id: cc.id, amount: "-100.00", date: ~D[2026-06-01]})

    {:ok, view, _html} = live(conn, ~p"/credit_card_links")

    view
    |> element("button[phx-click=confirm_suggestion][phx-value-payment-id=#{payment.id}]")
    |> render_click()

    assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
  end

  test "unlinking a pair clears the children", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    payment =
      transaction_fixture(%{account_id: checking.id, category_id: cc.id, amount: "-100.00", date: ~D[2026-03-05]})

    child = transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})
    Transactions.link_credit_card_batch([child.id], payment.id)

    {:ok, view, _html} = live(conn, ~p"/credit_card_links")

    view
    |> element("button[phx-click=unlink][phx-value-id=#{payment.id}]")
    |> render_click()

    assert is_nil(Repo.get!(Transaction, child.id).parent_transaction_id)
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/cash_lens_web/live/credit_card_link_live/index_test.exs`
Expected: FAIL — module `CashLensWeb.CreditCardLinkLive.Index` undefined / route not found.

- [ ] **Step 5: Implement the LiveView**

```elixir
# lib/cash_lens_web/live/credit_card_link_live/index.ex
defmodule CashLensWeb.CreditCardLinkLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_data(socket)}
  end

  @impl true
  def handle_event("confirm_suggestion", %{"payment-id" => payment_id, "batch-account-id" => account_id, "batch-inserted-at" => inserted_at}, socket) do
    batch = find_batch(socket.assigns.suggestions, payment_id, account_id, inserted_at)

    if batch do
      ids = Enum.map(batch.transactions, & &1.id)
      Transactions.link_credit_card_batch(ids, payment_id)
    end

    {:noreply, socket |> put_flash(:success, "Fatura vinculada!") |> load_data()}
  end

  @impl true
  def handle_event("link_batch", %{"payment-id" => payment_id, "batch-account-id" => account_id, "batch-inserted-at" => inserted_at}, socket) do
    batch = find_batch(socket.assigns.orphan_batches, nil, account_id, inserted_at)

    if batch do
      ids = Enum.map(batch.transactions, & &1.id)
      Transactions.link_credit_card_batch(ids, payment_id)
    end

    {:noreply, socket |> put_flash(:success, "Fatura vinculada!") |> load_data()}
  end

  @impl true
  def handle_event("unlink", %{"id" => parent_id}, socket) do
    Transactions.unlink_credit_card_children(parent_id)
    {:noreply, socket |> put_flash(:success, "Vínculo desfeito.") |> load_data()}
  end

  defp find_batch(collection, payment_id, account_id, inserted_at) do
    {:ok, parsed_inserted_at, _} = DateTime.from_iso8601(inserted_at)

    Enum.find_value(collection, fn
      {payment, batch} ->
        if (is_nil(payment_id) or payment.id == payment_id) and
             to_string(batch.account_id) == account_id and
             DateTime.compare(batch.inserted_at, parsed_inserted_at) == :eq,
           do: batch

      batch ->
        if to_string(batch.account_id) == account_id and
             DateTime.compare(batch.inserted_at, parsed_inserted_at) == :eq,
           do: batch
    end)
  end

  defp load_data(socket) do
    socket
    |> assign(:page_title, "Cartão de Crédito")
    |> assign(:suggestions, Transactions.list_credit_card_link_suggestions())
    |> assign(:orphan_batches, Transactions.list_credit_card_orphan_batches())
    |> assign(:divergent, Transactions.list_credit_card_divergent_links())
    |> assign(:linked, Transactions.list_credit_card_linked())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 max-w-4xl mx-auto">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Cartão de Crédito</h1>
          <p class="text-xs opacity-50 mt-1">
            {length(@suggestions)} faturas para confirmar · {length(@divergent)} com divergência
          </p>
        </div>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Pares Sugeridos</h2>
        </div>
        <div :if={@suggestions == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Sem sugestões.
        </div>
        <table :if={@suggestions != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={{payment, batch} <- @suggestions} class="hover">
              <td class="font-mono opacity-60 whitespace-nowrap">
                {Calendar.strftime(payment.date, "%d/%m/%Y")}
              </td>
              <td>{payment.description} <span class="opacity-50">({payment.account && payment.account.name})</span></td>
              <td class="text-right font-mono font-black">{format_currency(payment.amount)}</td>
              <td class="text-right">
                <button
                  class="btn btn-success btn-xs"
                  phx-click="confirm_suggestion"
                  phx-value-payment-id={payment.id}
                  phx-value-batch-account-id={batch.account_id}
                  phx-value-batch-inserted-at={DateTime.to_iso8601(batch.inserted_at)}
                >
                  <.icon name="hero-check" class="size-3" /> Confirmar
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Sem Pai Encontrado</h2>
        </div>
        <div :if={@orphan_batches == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma fatura órfã.
        </div>
        <table :if={@orphan_batches != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={batch <- @orphan_batches} class="hover">
              <td>{batch.account && batch.account.name}</td>
              <td>{length(batch.transactions)} transações</td>
              <td class="text-right font-mono font-black">{format_currency(batch.total)}</td>
              <td class="text-right opacity-40 text-[10px]">vínculo manual na edição da transação</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-error/40 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm text-error">
            Vinculados com Divergência
          </h2>
        </div>
        <div :if={@divergent == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma divergência.
        </div>
        <table :if={@divergent != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={%{parent: parent, children_total: total} <- @divergent} class="hover">
              <td>{parent.description}</td>
              <td class="text-right font-mono">{format_currency(parent.amount)}</td>
              <td class="text-right font-mono text-error">{format_currency(Decimal.negate(total))}</td>
              <td class="text-right">
                <button class="btn btn-ghost btn-xs text-error" phx-click="unlink" phx-value-id={parent.id}>
                  <.icon name="hero-link-slash" class="size-3" /> Desvincular
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Vinculados OK</h2>
        </div>
        <div :if={@linked == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma fatura vinculada ainda.
        </div>
        <table :if={@linked != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={%{parent: parent} <- @linked} class="hover">
              <td>{parent.description}</td>
              <td class="text-right font-mono font-black">{format_currency(parent.amount)}</td>
              <td class="text-right">
                <button class="btn btn-ghost btn-xs text-error" phx-click="unlink" phx-value-id={parent.id}>
                  <.icon name="hero-link-slash" class="size-3" /> Desvincular
                </button>
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

Note: `format_currency/1` is the existing helper already used in `TransferLive.Index` — confirm its import path with `grep -n "format_currency" lib/cash_lens_web/live/transfer_live/index.ex lib/cash_lens_web.ex` and add the same `import`/`use` if `CashLensWeb, :live_view` doesn't already bring it in (it does for `TransferLive.Index`, which has no extra import, so it's already available through `use CashLensWeb, :live_view`).

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/cash_lens_web/live/credit_card_link_live/index_test.exs`
Expected: PASS.

- [ ] **Step 7: Manual smoke check**

Run: `mix phx.server` (or your existing dev-server launch.json), then visit `http://localhost:4000/credit_card_links` in a browser and confirm the page renders with all 4 section headers and the nav link "Cartão de Crédito" appears next to "Transferências". Stop the server after checking.

- [ ] **Step 8: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add lib/cash_lens_web/live/credit_card_link_live/index.ex lib/cash_lens_web/router.ex lib/cash_lens_web/components/layouts/app.html.heex test/cash_lens_web/live/credit_card_link_live/index_test.exs
git commit -m "feat(web): add /credit_card_links reconciliation screen"
```

---

### Task 12: Data migration for historical transfer-linked pairs

**Spec section:** 5.

**Files:**
- Create: `lib/mix/tasks/migrate_credit_card_transfers.ex`
- Test: `test/mix/tasks/migrate_credit_card_transfers_test.exs`

**Interfaces:**
- Consumes: `CreditCardMatcher.match_payment/2` (Task 4), `Categories.get_category_by_slug/1`.
- Produces: `Mix.Tasks.MigrateCreditCardTransfers.run/1`, callable as `mix migrate_credit_card_transfers`. Side effects only (DB writes + log output); no return value relied upon by other code.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/mix/tasks/migrate_credit_card_transfers_test.exs
defmodule Mix.Tasks.MigrateCreditCardTransfersTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures
  import ExUnit.CaptureLog

  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule

  defp insert_raw(attrs) do
    %Transaction{} |> Transaction.changeset(attrs) |> Repo.insert!()
  end

  defp link(tx_a, tx_b) do
    key = Ecto.UUID.generate()

    {2, _} =
      from(t in Transaction, where: t.id in [^tx_a.id, ^tx_b.id])
      |> Repo.update_all(set: [transfer_key: key])

    key
  end

  test "migrates a pair covered by an active mirror-creating TransferRule" do
    transfer_cat = category_fixture(%{name: "Transferência", slug: "transfer"})
    cc_cat = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    Repo.insert!(%TransferRule{
      description_patterns: ["fatura"],
      source_account_id: checking.id,
      destination_account_id: card.id,
      create_mirror: true
    })

    payment =
      insert_raw(%{
        account_id: checking.id,
        category_id: transfer_cat.id,
        amount: "-500.00",
        date: ~D[2026-01-15],
        description: "Pagamento fatura"
      })

    mirror =
      insert_raw(%{
        account_id: card.id,
        category_id: transfer_cat.id,
        amount: "500.00",
        date: ~D[2026-01-15],
        description: "Pagamento fatura"
      })

    link(payment, mirror)

    real_purchase =
      insert_raw(%{
        account_id: card.id,
        amount: "-500.00",
        date: ~D[2026-01-10],
        description: "Uber"
      })

    capture_log(fn -> Mix.Tasks.MigrateCreditCardTransfers.run([]) end)

    updated_payment = Repo.get!(Transaction, payment.id)
    assert updated_payment.category_id == cc_cat.id
    assert is_nil(updated_payment.transfer_key)
    assert is_nil(Repo.get(Transaction, mirror.id))
    assert Repo.get!(Transaction, real_purchase.id).parent_transaction_id == updated_payment.id
  end

  test "does not touch a transfer_key pair with no matching TransferRule" do
    transfer_cat = category_fixture(%{name: "Transferência", slug: "transfer"})
    category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    manual_a =
      insert_raw(%{
        account_id: checking.id,
        category_id: transfer_cat.id,
        amount: "-300.00",
        date: ~D[2026-02-01],
        description: "Transferência manual"
      })

    manual_b =
      insert_raw(%{
        account_id: card.id,
        category_id: transfer_cat.id,
        amount: "300.00",
        date: ~D[2026-02-01],
        description: "Transferência manual"
      })

    link(manual_a, manual_b)

    capture_log(fn -> Mix.Tasks.MigrateCreditCardTransfers.run([]) end)

    assert Repo.get!(Transaction, manual_a.id).category_id == transfer_cat.id
    assert Repo.get!(Transaction, manual_b.id) != nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mix/tasks/migrate_credit_card_transfers_test.exs`
Expected: FAIL — `Mix.Tasks.MigrateCreditCardTransfers` module undefined.

- [ ] **Step 3: Implement the Mix task**

```elixir
# lib/mix/tasks/migrate_credit_card_transfers.ex
defmodule Mix.Tasks.MigrateCreditCardTransfers do
  @moduledoc """
  One-off data migration: converts historical transfer-linked pairs created
  by `TransferRuleApplier`'s old credit-card mirror behavior into the new
  parent/child model (spec section 5).

  Only touches a `transfer_key` pair when the payer side matches an active
  `TransferRule` (`destination_account_id` is a credit-card account,
  `create_mirror: true`) — that is the only combination guaranteed to have
  created a fictitious mirror, so it is the only case safe to delete
  automatically. Every other transfer_key pair touching a credit-card
  account is left untouched and logged for manual review.

      mix migrate_credit_card_transfers
  """
  use Mix.Task

  import Ecto.Query
  require Logger

  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule

  @shortdoc "Migrates historical credit-card transfer pairs to the parent/child model"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        Logger.error(
          "MigrateCreditCardTransfers: 'cartao-de-credito' category not found — run seeds first."
        )

      category ->
        migrate(category)
    end
  end

  defp migrate(category) do
    rules = mirror_rules_by_destination()

    {migrated, ambiguous} =
      transfer_pairs()
      |> Enum.split_with(fn {payer, card_side} -> eligible?(payer, card_side, rules) end)

    Enum.each(migrated, fn {payer, card_side} -> migrate_pair(payer, card_side, category) end)

    Logger.info(
      "MigrateCreditCardTransfers: migrated #{length(migrated)} pair(s); " <>
        "#{length(ambiguous)} pair(s) left untouched for manual review: " <>
        inspect(Enum.map(ambiguous, fn {a, b} -> {a.id, b.id} end))
    )
  end

  defp mirror_rules_by_destination do
    from(r in TransferRule, where: r.create_mirror == true)
    |> Repo.all()
    |> Map.new(&{&1.destination_account_id, &1})
  end

  defp transfer_pairs do
    from(a in Transaction,
      join: b in Transaction,
      on: a.transfer_key == b.transfer_key and a.id < b.id,
      where: not is_nil(a.transfer_key),
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.map(&order_by_credit_card_side/1)
  end

  defp order_by_credit_card_side({a, b}) do
    account_a = Repo.get!(CashLens.Accounts.Account, a.account_id)
    account_b = Repo.get!(CashLens.Accounts.Account, b.account_id)

    cond do
      account_b.is_credit_card -> {a, %{tx: b, account: account_b}}
      account_a.is_credit_card -> {b, %{tx: a, account: account_a}}
      true -> {a, %{tx: nil, account: nil}}
    end
  end

  defp eligible?(_payer, %{tx: nil}, _rules), do: false

  defp eligible?(payer, %{account: card_account}, rules) do
    case Map.get(rules, card_account.id) do
      %TransferRule{source_account_id: source_id} -> source_id == payer.account_id
      nil -> false
    end
  end

  defp migrate_pair(payer, %{tx: mirror, account: card_account}, category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Transaction, where: t.id == ^payer.id)
    |> Repo.update_all(set: [category_id: category.id, transfer_key: nil, updated_at: now])

    Repo.delete!(mirror)

    updated_payer = Repo.get!(Transaction, payer.id)
    CreditCardMatcher.match_payment(updated_payer, card_account.id)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mix/tasks/migrate_credit_card_transfers_test.exs`
Expected: PASS.

- [ ] **Step 5: Quality gate**

Run: `mix compile --warnings-as-errors && mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/migrate_credit_card_transfers.ex test/mix/tasks/migrate_credit_card_transfers_test.exs
git commit -m "feat(mix): add migrate_credit_card_transfers data migration task"
```

**Do not run `mix migrate_credit_card_transfers` against the real dev/prod database as part of this plan** — that is a one-time, user-triggered operation the user should run themselves after reviewing this task's diff, since it deletes rows. Mention this explicitly when reporting this task as done.

---

### Task 13: Full regression pass and final review

**Files:** none (verification only).

- [ ] **Step 1: Run the full quality gate**

Run: `mix quality_check`
Expected: every step (`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `deps.unlock --unused` if included, `test`) passes with zero failures/warnings.

If `mix quality_check` is not a single alias covering tests, also run explicitly:

Run: `mix test`
Expected: `0 failures`.

- [ ] **Step 2: Re-read the spec end to end and check every section has a task**

Re-open `docs/superpowers/specs/2026-06-30-credit-card-sub-transactions-design.md` and confirm:
- Section 1 (schema) → Task 1.
- Section 2 (category seed) → Task 2.
- Section 3 (`TransferRuleApplier`) → Task 6.
- Section 4 (`CreditCardMatcher`, guard, reapply) → Tasks 3, 4, 7.
- Section 5 (data migration) → Task 12.
- Section 6 (screen) → Tasks 10, 11.
- Section 7 (category breakdown anti-join) → Task 9.
- Section 8 (totals exclude category) → Task 8.
- Every bullet in the spec's "Testes" section maps to an assertion written in Tasks 1–12.

If a gap is found, stop and add a task before proceeding.

- [ ] **Step 3: Manual smoke test of the end-to-end flow**

With the dev server running (`mix phx.server`), in the UI:
1. Create (or confirm) a checking account and a credit-card account (`is_credit_card: true`).
2. Create a `TransferRule` at `/admin/transfer_rules` from the checking account to the credit-card account with `create_mirror: true`.
3. Import a credit-card statement file into the credit-card account (any supported parser).
4. Manually create a transaction in the checking account whose description matches the rule's pattern and whose amount is `-1 * (sum of the imported statement)`, dated within 5 days of the statement's latest transaction.
5. Confirm: the checking-account transaction is now categorized "Cartão de Crédito" (not "Transferência"), and visiting `/credit_card_links` shows it under "Vinculados OK" with its children listed.
6. Confirm `/` (dashboard) and the category-breakdown chart no longer show "Cartão de Crédito" as a spending category for that month, but do show the real categories of the imported purchases.

Report the outcome of this manual check explicitly — this is the only step in the whole plan that exercises the real UI end-to-end; do not skip it.

- [ ] **Step 4: Final commit (if anything was left uncommitted)**

Run: `git status`

If clean, nothing to do. If anything is unstaged (e.g. a fix made during Step 1's regression pass), stage and commit it with a message describing the specific fix — do not bundle unrelated changes.
