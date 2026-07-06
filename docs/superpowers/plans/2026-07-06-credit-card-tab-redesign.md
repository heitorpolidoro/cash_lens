# Credit Card Tab Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the confusing 6-section `/credit_card_links` reconciliation screen with a fatura-centric model where each imported file is one statement, matching actually links, and the UI is an overview → detail.

**Architecture:** A new `credit_card_statements` table (id = a per-file UUID stamped on `transactions.import_batch_id`) makes "fatura = imported file". The PDF parser also yields due date + total. Import creates a statement per file and auto-links the matching payment. A backfill mix task re-reads files and stamps existing rows by fingerprint (categories untouched). The LiveView becomes a filterable statement table + detail.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/Postgres, ExUnit.

## Global Constraints

- Elixir/Phoenix project; run tests with `mix test`, format with `mix format`.
- All primary keys are `:binary_id` (UUID); `timestamps(type: :utc_datetime)`.
- Money is `Decimal`; compare with `Decimal.equal?/2`, never `==`.
- Credit-card category is looked up by slug `"cartao-de-credito"`.
- Credit-card accounts have `is_credit_card == true`.
- Never persist future-dated transactions (existing ingestor rule).
- Preserve dedupe: re-import must not create duplicates (fingerprint unique index).

---

### Task 1: Migration + schema field for statements

**Files:**
- Create: `priv/repo/migrations/20260706120000_create_credit_card_statements.exs`
- Modify: `lib/cash_lens/transactions/transaction.ex` (add field + cast)

**Interfaces:**
- Produces: table `credit_card_statements(id, account_id, competencia, due_date, total_a_pagar, source_file, payment_transaction_id, inserted_at, updated_at)`; `transactions.import_batch_id :binary_id`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule CashLens.Repo.Migrations.CreateCreditCardStatements do
  use Ecto.Migration

  def change do
    create table(:credit_card_statements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, on_delete: :delete_all, type: :binary_id), null: false
      add :competencia, :date
      add :due_date, :date
      add :total_a_pagar, :decimal
      add :source_file, :string
      add :payment_transaction_id, references(:transactions, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:credit_card_statements, [:account_id])
    create index(:credit_card_statements, [:payment_transaction_id])

    alter table(:transactions) do
      add :import_batch_id, :binary_id
    end

    create index(:transactions, [:import_batch_id])
  end
end
```

- [ ] **Step 2: Add the field to the Transaction schema**

In `lib/cash_lens/transactions/transaction.ex`, add to the `schema "transactions"` block (near `parent_transaction_id`):

```elixir
    field :import_batch_id, :binary_id
```

And add `:import_batch_id` to the `cast/3` list in `changeset/2`.

- [ ] **Step 3: Run the migration**

Run: `export $(cat .env | xargs) && mix ecto.migrate`
Expected: creates `credit_card_statements`, adds `transactions.import_batch_id`.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260706120000_create_credit_card_statements.exs lib/cash_lens/transactions/transaction.ex
git commit -m "feat(credit-card): add credit_card_statements table and import_batch_id"
```

---

### Task 2: Statement schema

**Files:**
- Create: `lib/cash_lens/credit_cards/statement.ex`
- Test: `test/cash_lens/credit_cards/statement_test.exs`

**Interfaces:**
- Produces: `CashLens.CreditCards.Statement` struct with `changeset/2`; fields `account_id, competencia, due_date, total_a_pagar, source_file, payment_transaction_id`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CashLens.CreditCards.StatementTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards.Statement

  test "changeset requires account_id" do
    changeset = Statement.changeset(%Statement{}, %{})
    refute changeset.valid?
    assert %{account_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset accepts full attrs" do
    attrs = %{
      account_id: Ecto.UUID.generate(),
      competencia: ~D[2026-06-01],
      due_date: ~D[2026-06-15],
      total_a_pagar: Decimal.new("3812.40"),
      source_file: "ourocard_2026-06.pdf"
    }

    assert Statement.changeset(%Statement{}, attrs).valid?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/credit_cards/statement_test.exs`
Expected: FAIL — `CashLens.CreditCards.Statement` is undefined.

- [ ] **Step 3: Write the schema**

```elixir
defmodule CashLens.CreditCards.Statement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_card_statements" do
    field :competencia, :date
    field :due_date, :date
    field :total_a_pagar, :decimal
    field :source_file, :string

    belongs_to :account, CashLens.Accounts.Account
    belongs_to :payment_transaction, CashLens.Transactions.Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(statement, attrs) do
    statement
    |> cast(attrs, [
      :id,
      :account_id,
      :competencia,
      :due_date,
      :total_a_pagar,
      :source_file,
      :payment_transaction_id
    ])
    |> validate_required([:account_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:payment_transaction_id)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/credit_cards/statement_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/credit_cards/statement.ex test/cash_lens/credit_cards/statement_test.exs
git commit -m "feat(credit-card): add Statement schema"
```

---

### Task 3: Context — create/get + status helper

**Files:**
- Create: `lib/cash_lens/credit_cards.ex`
- Create: `test/support/fixtures/credit_cards_fixtures.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `CashLens.CreditCards.Statement`.
- Produces:
  - `CreditCards.create_statement(attrs) :: {:ok, Statement.t()} | {:error, Changeset.t()}`
  - `CreditCards.get_statement!(id) :: Statement.t()`
  - `CreditCards.statement_status(statement, line_total) :: :linked | :open | :divergent`
    (`:open` when no payment linked; `:divergent` when linked but `line_total`/`total_a_pagar` mismatch the payment; else `:linked`)
  - Fixture `statement_fixture(attrs \\ %{})`.

- [ ] **Step 1: Write the fixture**

```elixir
defmodule CashLens.CreditCardsFixtures do
  @moduledoc "Test helpers for CashLens.CreditCards."

  def statement_fixture(attrs \\ %{}) do
    account =
      Map.get_lazy(attrs, :account, fn ->
        CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      end)

    {:ok, statement} =
      attrs
      |> Map.drop([:account])
      |> Enum.into(%{
        account_id: account.id,
        competencia: ~D[2026-06-01],
        due_date: ~D[2026-06-15],
        total_a_pagar: Decimal.new("100.00"),
        source_file: "fatura.pdf"
      })
      |> CashLens.CreditCards.create_statement()

    statement
  end
end
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule CashLens.CreditCardsTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards
  import CashLens.CreditCardsFixtures

  test "create_statement and get_statement!" do
    s = statement_fixture()
    assert CreditCards.get_statement!(s.id).id == s.id
  end

  test "statement_status is :open without a payment" do
    s = statement_fixture(%{payment_transaction_id: nil})
    assert CreditCards.statement_status(s, Decimal.new("100.00")) == :open
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `CashLens.CreditCards` undefined.

- [ ] **Step 4: Write the context**

```elixir
defmodule CashLens.CreditCards do
  @moduledoc "Credit-card statement (fatura) context."
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.CreditCards.Statement

  def create_statement(attrs) do
    %Statement{}
    |> Statement.changeset(attrs)
    |> Repo.insert()
  end

  def get_statement!(id), do: Repo.get!(Statement, id)

  @doc """
  :open  — no payment linked.
  :divergent — payment linked but its amount differs from the statement's
    total_a_pagar (falling back to line_total when total is nil).
  :linked — payment linked and amount matches.
  """
  def statement_status(%Statement{payment_transaction_id: nil}, _line_total), do: :open

  def statement_status(%Statement{} = statement, line_total) do
    payment = Repo.get!(CashLens.Transactions.Transaction, statement.payment_transaction_id)
    target = statement.total_a_pagar || line_total

    if Decimal.equal?(payment.amount, target) or
         Decimal.equal?(payment.amount, Decimal.negate(target)) do
      :linked
    else
      :divergent
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/credit_cards.ex test/support/fixtures/credit_cards_fixtures.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): CreditCards context with create/get/status"
```

---

### Task 4: Context — overview list + detail

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `Statement`, `Transactions.Transaction`.
- Produces:
  - `CreditCards.list_statements() :: [%{statement: Statement.t(), account: Account.t(), line_total: Decimal.t(), line_count: non_neg_integer(), status: :linked | :open | :divergent}]` sorted by `due_date`/`competencia` desc.
  - `CreditCards.get_statement_detail(id) :: %{statement: Statement.t(), account: Account.t(), transactions: [Transaction.t()], line_total: Decimal.t(), payment: Transaction.t() | nil, status: atom()}`
  - `CreditCards.statement_transactions(statement_id) :: [Transaction.t()]` (helper).

- [ ] **Step 1: Write the failing test**

```elixir
test "list_statements returns rows with line totals and status" do
  account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  s = statement_fixture(%{account: account, total_a_pagar: Decimal.new("30.00")})

  CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: account.id, amount: Decimal.new("10.00"), import_batch_id: s.id
  })
  CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: account.id, amount: Decimal.new("20.00"), import_batch_id: s.id
  })

  [row] = CashLens.CreditCards.list_statements()
  assert row.statement.id == s.id
  assert Decimal.equal?(row.line_total, Decimal.new("30.00"))
  assert row.line_count == 2
  assert row.status == :open
end

test "get_statement_detail returns transactions and payment" do
  account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  s = statement_fixture(%{account: account})
  CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: account.id, amount: Decimal.new("5.00"), import_batch_id: s.id
  })

  detail = CashLens.CreditCards.get_statement_detail(s.id)
  assert length(detail.transactions) == 1
  assert detail.payment == nil
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `list_statements/0` undefined.

- [ ] **Step 3: Implement the functions**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  alias CashLens.Transactions.Transaction

  def statement_transactions(statement_id) do
    from(t in Transaction,
      where: t.import_batch_id == ^statement_id,
      order_by: [asc: t.date, asc: t.inserted_at],
      preload: [:category]
    )
    |> Repo.all()
  end

  def list_statements do
    statements =
      from(s in Statement, preload: [:account], order_by: [desc: s.due_date, desc: s.competencia])
      |> Repo.all()

    totals =
      from(t in Transaction,
        where: not is_nil(t.import_batch_id),
        group_by: t.import_batch_id,
        select: {t.import_batch_id, sum(t.amount), count(t.id)}
      )
      |> Repo.all()
      |> Map.new(fn {id, sum, count} -> {id, {sum || Decimal.new(0), count}} end)

    Enum.map(statements, fn s ->
      {line_total, line_count} = Map.get(totals, s.id, {Decimal.new(0), 0})

      %{
        statement: s,
        account: s.account,
        line_total: line_total,
        line_count: line_count,
        status: statement_status(s, line_total)
      }
    end)
  end

  def get_statement_detail(id) do
    statement = from(s in Statement, where: s.id == ^id, preload: [:account]) |> Repo.one!()
    transactions = statement_transactions(id)
    line_total = Enum.reduce(transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))

    payment =
      statement.payment_transaction_id &&
        Repo.get(Transaction, statement.payment_transaction_id) |> Repo.preload(:account)

    %{
      statement: statement,
      account: statement.account,
      transactions: transactions,
      line_total: line_total,
      payment: payment,
      status: statement_status(statement, line_total)
    }
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): list_statements and get_statement_detail"
```

---

### Task 5: Context — link / unlink / suggest payment

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex`
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `Statement`, `Transaction`, category slug `"cartao-de-credito"`.
- Produces:
  - `CreditCards.link_payment(statement, payment_id) :: {:ok, Statement.t()}` — sets `statement.payment_transaction_id` AND every `import_batch_id`-child's `parent_transaction_id = payment_id`, in one transaction.
  - `CreditCards.unlink_payment(statement) :: {:ok, Statement.t()}` — clears both.
  - `CreditCards.suggest_payment(statement) :: Transaction.t() | nil` — best unlinked cartão-de-crédito payment (amount closest to `total_a_pagar`, then nearest to `due_date`), in a different account.

- [ ] **Step 1: Write the failing test**

```elixir
test "link_payment sets statement payment and children parents" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  bank = CashLens.AccountsFixtures.account_fixture(%{})
  s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("30.00")})

  child = CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: card.id, amount: Decimal.new("30.00"), import_batch_id: s.id
  })
  payment = CashLens.TransactionsFixtures.transaction_fixture(%{
    account_id: bank.id, amount: Decimal.new("30.00")
  })

  {:ok, s2} = CashLens.CreditCards.link_payment(s, payment.id)
  assert s2.payment_transaction_id == payment.id
  assert CashLens.Repo.get!(CashLens.Transactions.Transaction, child.id).parent_transaction_id == payment.id

  {:ok, s3} = CashLens.CreditCards.unlink_payment(s2)
  assert s3.payment_transaction_id == nil
  assert CashLens.Repo.get!(CashLens.Transactions.Transaction, child.id).parent_transaction_id == nil
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `link_payment/2` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  alias Ecto.Multi

  def link_payment(%Statement{} = statement, payment_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update_all(
      :children,
      from(t in Transaction, where: t.import_batch_id == ^statement.id),
      set: [parent_transaction_id: payment_id, updated_at: now]
    )
    |> Multi.update(:statement, Statement.changeset(statement, %{payment_transaction_id: payment_id}))
    |> Repo.transaction()
    |> case do
      {:ok, %{statement: s}} -> {:ok, s}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  def unlink_payment(%Statement{} = statement) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update_all(
      :children,
      from(t in Transaction, where: t.import_batch_id == ^statement.id),
      set: [parent_transaction_id: nil, updated_at: now]
    )
    |> Multi.update(:statement, Statement.changeset(statement, %{payment_transaction_id: nil}))
    |> Repo.transaction()
    |> case do
      {:ok, %{statement: s}} -> {:ok, s}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  def suggest_payment(%Statement{} = statement) do
    case CashLens.Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        nil

      category ->
        target = statement.total_a_pagar
        due = statement.due_date

        from(t in Transaction,
          where: t.category_id == ^category.id,
          where: t.account_id != ^statement.account_id,
          where: is_nil(t.parent_transaction_id),
          preload: [:account]
        )
        |> Repo.all()
        |> Enum.sort_by(fn t ->
          amount_diff = if target, do: Decimal.abs(Decimal.sub(t.amount, target)), else: Decimal.new(0)
          date_diff = if due, do: abs(Date.diff(t.date, due)), else: 0
          {Decimal.to_float(amount_diff), date_diff}
        end)
        |> List.first()
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(credit-card): link/unlink/suggest payment"
```

---

### Task 6: Matcher — auto-link exact on import

**Files:**
- Create: `lib/cash_lens/credit_cards/matcher.ex`
- Test: `test/cash_lens/credit_cards/matcher_test.exs`

**Interfaces:**
- Consumes: `Statement`, `Transaction`, `CreditCards.link_payment/2`, category slug.
- Produces:
  - `CashLens.CreditCards.Matcher.auto_link(statement, line_total) :: {:linked, Transaction.t()} | :no_match | :ambiguous`
    - target = `statement.total_a_pagar || line_total`
    - candidates: category `cartao-de-credito`, `account_id != statement.account_id`, `is_nil(parent_transaction_id)`, `amount == target` (or `== -target`), and `abs(date - reference_date) <= 15` where reference_date = `statement.due_date || competencia end`.
    - exactly one candidate → `link_payment` → `{:linked, payment}`; zero → `:no_match`; more than one → `:ambiguous` (no auto-link).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CashLens.CreditCards.MatcherTest do
  use CashLens.DataCase, async: true
  import CashLens.CreditCardsFixtures
  alias CashLens.CreditCards.Matcher

  setup do
    CashLens.CategoriesFixtures.category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
    :ok
  end

  test "auto_link links the single exact-amount payment within the window" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})
    cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("30.00"), due_date: ~D[2026-06-15]})

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id, amount: Decimal.new("30.00"), import_batch_id: s.id, date: ~D[2026-06-05]
    })
    payment = CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: bank.id, amount: Decimal.new("30.00"), category_id: cat.id, date: ~D[2026-06-16]
    })

    assert {:linked, linked} = Matcher.auto_link(s, Decimal.new("30.00"))
    assert linked.id == payment.id
    assert CashLens.CreditCards.get_statement!(s.id).payment_transaction_id == payment.id
  end

  test "auto_link returns :no_match when no candidate amount matches" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("99.00")})
    assert Matcher.auto_link(s, Decimal.new("99.00")) == :no_match
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/credit_cards/matcher_test.exs`
Expected: FAIL — `Matcher` undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule CashLens.CreditCards.Matcher do
  @moduledoc "Auto-links a statement to its exact-amount payment on import."
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.CreditCards
  alias CashLens.Transactions.Transaction

  @window_days 15

  def auto_link(statement, line_total) do
    with category when not is_nil(category) <-
           CashLens.Categories.get_category_by_slug("cartao-de-credito") do
      target = statement.total_a_pagar || line_total
      ref = statement.due_date || statement.competencia

      candidates =
        from(t in Transaction,
          where: t.category_id == ^category.id,
          where: t.account_id != ^statement.account_id,
          where: is_nil(t.parent_transaction_id),
          where: t.amount == ^target or t.amount == ^Decimal.negate(target)
        )
        |> Repo.all()
        |> Enum.filter(&within_window?(&1, ref))

      case candidates do
        [payment] ->
          {:ok, _} = CreditCards.link_payment(statement, payment.id)
          {:linked, payment}

        [] ->
          :no_match

        _ ->
          :ambiguous
      end
    else
      _ -> :no_match
    end
  end

  defp within_window?(_payment, nil), do: true
  defp within_window?(payment, ref), do: abs(Date.diff(payment.date, ref)) <= @window_days
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/credit_cards/matcher_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/credit_cards/matcher.ex test/cash_lens/credit_cards/matcher_test.exs
git commit -m "feat(credit-card): statement auto-link matcher"
```

---

### Task 7: Parser — extract statement metadata

**Files:**
- Modify: `lib/cash_lens/parsers/pdf_parser.ex`
- Test: `test/cash_lens/parsers/pdf_parser_test.exs` (add cases; create file if absent)

**Interfaces:**
- Produces: `CashLens.Parsers.PDFParser.extract_statement_meta(text) :: %{due_date: Date.t() | nil, total_a_pagar: Decimal.t() | nil, competencia: Date.t() | nil}`
  - `due_date` reuses the existing `Vencimento` regex.
  - `total_a_pagar` parses the amount on the "TOTAL DA FATURA"/"TOTAL PARA ..." line.
  - `competencia` = first day of `due_date`'s month (or nil).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CashLens.Parsers.PDFParserTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.PDFParser

  test "extract_statement_meta pulls due date, total and competencia" do
    text = """
    Vencimento 15/06/2026
    01/06 UBER TRIP 27,90
    TOTAL DA FATURA EM REAL 3.812,40
    """

    meta = PDFParser.extract_statement_meta(text)
    assert meta.due_date == ~D[2026-06-15]
    assert Decimal.equal?(meta.total_a_pagar, Decimal.new("3812.40"))
    assert meta.competencia == ~D[2026-06-01]
  end

  test "extract_statement_meta degrades to nils when absent" do
    meta = PDFParser.extract_statement_meta("no relevant lines")
    assert meta.due_date == nil
    assert meta.total_a_pagar == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/pdf_parser_test.exs`
Expected: FAIL — `extract_statement_meta/1` undefined.

- [ ] **Step 3: Implement**

Add a public function to `lib/cash_lens/parsers/pdf_parser.ex` (reuse the private `extract_statement_date/1` and `parse_amount/1`):

```elixir
  @doc """
  Statement-level metadata for a credit-card PDF: due date (Vencimento),
  total_a_pagar (the "TOTAL DA FATURA" amount, previously used only as an
  end-of-table marker) and competencia (first day of the due month). Any
  field is nil when the source does not carry it.
  """
  def extract_statement_meta(text) do
    due = extract_statement_date_or_nil(text)

    %{
      due_date: due,
      total_a_pagar: extract_total(text),
      competencia: due && Date.beginning_of_month(due)
    }
  end

  defp extract_statement_date_or_nil(text) do
    case Regex.run(~r/Vencimento\s*(?:\r?\n\s*)?(\d{2})\/(\d{2})\/(\d{4})/i, text) do
      [_, d, m, y] -> Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))
      _ -> nil
    end
  end

  defp extract_total(text) do
    regex = ~r/TOTAL (?:DA FATURA|PARA)[^\d]*?([\d.]+,\d{2})/i

    case Regex.run(regex, text) do
      [_, amount_str] -> parse_amount(amount_str)
      _ -> nil
    end
  end
```

Note: if `parse_amount/1` returns a signed/plain Decimal, `total_a_pagar` should be the positive statement total; take `Decimal.abs/1` if needed to match how card totals are stored.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/parsers/pdf_parser_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/parsers/pdf_parser.ex test/cash_lens/parsers/pdf_parser_test.exs
git commit -m "feat(parser): extract credit-card statement metadata"
```

---

### Task 8: Ingestor — create statement per file, stamp import_batch_id

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex`
- Test: `test/cash_lens/parsers/ingestor_test.exs` (add cases)

**Interfaces:**
- Consumes: `CreditCards.create_statement/1`, `PDFParser.extract_statement_meta/1`, `Matcher.auto_link/2`.
- Produces: after importing a credit-card file, a `credit_card_statements` row exists and every inserted row from that file has `import_batch_id == statement.id`. Non-credit-card imports are unchanged (`import_batch_id` stays nil).

- [ ] **Step 1: Write the failing test**

```elixir
test "importing a credit-card file creates a statement and stamps import_batch_id" do
  account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, parser_type: "bb_csv"})
  # use whatever fixture content your ingestor tests already use for this parser;
  # assert the statement + stamping afterwards:
  {:ok, %{imported: n}} = import_fixture_for(account)   # existing test helper
  assert n > 0

  [statement] = CashLens.Repo.all(CashLens.CreditCards.Statement)
  assert statement.account_id == account.id

  stamped =
    CashLens.Repo.all(
      from t in CashLens.Transactions.Transaction,
        where: t.account_id == ^account.id and t.import_batch_id == ^statement.id
    )

  assert length(stamped) == n
end
```

(Adapt `import_fixture_for/1` to the existing ingestor test's import path/content helper. If a card-PDF fixture is available, also assert `statement.total_a_pagar` and `due_date` are populated.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: FAIL — no statement created.

- [ ] **Step 3: Implement**

Thread `account` and statement id through the import. Change `process_imported_content/4` to pass the parsed text and account into `finalize_import`, and create the statement before inserting:

```elixir
  defp process_imported_content(content, account, file_path, notify_fn) do
    content = prepare_content(content, account, file_path)
    Logger.info("INGESTOR: #{account.parser_type} <- #{file_path} (#{account.name})")

    case parse(content, account.parser_type) do
      {:error, reason} ->
        Logger.error("INGESTOR: Parsing failed: #{reason}")
        {:error, reason}

      transactions_data ->
        Logger.info("INGESTOR: Parser returned #{length(transactions_data)} transactions.")
        if notify_fn, do: notify_fn.(length(transactions_data))
        statement_id = maybe_create_statement(account, content, file_path)
        finalize_import(transactions_data, account.id, statement_id)
    end
  end

  # Returns the new statement id for credit-card accounts (so rows can be
  # stamped and matched), or nil for regular accounts.
  defp maybe_create_statement(%{is_credit_card: true} = account, content, file_path) do
    meta =
      if String.ends_with?(file_path, ".pdf") do
        CashLens.Parsers.PDFParser.extract_statement_meta(content)
      else
        %{due_date: nil, total_a_pagar: nil, competencia: nil}
      end

    {:ok, statement} =
      CashLens.CreditCards.create_statement(%{
        account_id: account.id,
        due_date: meta.due_date,
        total_a_pagar: meta.total_a_pagar,
        competencia: meta.competencia,
        source_file: Path.basename(file_path)
      })

    statement.id
  end

  defp maybe_create_statement(_account, _content, _file_path), do: nil
```

Add `statement_id` to `finalize_import/3`, `prepare_entries/3`, `prepare_transaction_entry/5` (put `:import_batch_id` on the entry map), and `process_entries/4`:

```elixir
  defp finalize_import(transactions_data, account_id, statement_id) do
    today = Date.utc_today()
    transactions_data = Enum.reject(transactions_data, &(Date.compare(&1.date, today) == :gt))

    {entries, failed} = prepare_entries(transactions_data, account_id, statement_id)
    {inserted_count, affected_account_ids} =
      process_entries(entries, transactions_data, account_id, statement_id)

    Enum.each(affected_account_ids, &Accounting.rebuild_account_balances/1)
    skipped = length(entries) - inserted_count
    {:ok, %{imported: inserted_count, skipped: skipped, failed: failed}}
  end
```

In `prepare_transaction_entry/5`, after `Map.put(:updated_at, now)` add `|> Map.put(:import_batch_id, statement_id)` (nil for non-card accounts is fine — column is nullable).

In `process_entries/4`, replace the `CreditCardMatcher.match_batch(inserted_transactions)` call with statement matching:

```elixir
    if statement_id do
      statement = CashLens.CreditCards.get_statement!(statement_id)

      line_total =
        Enum.reduce(inserted_transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))

      CashLens.CreditCards.Matcher.auto_link(statement, line_total)
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite to catch signature breaks**

Run: `mix test`
Expected: PASS (fix any callers of the changed private arities).

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens/parsers/ingestor.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "feat(ingestor): create statement per file and stamp import_batch_id"
```

---

### Task 9: Backfill mix task (re-read files, stamp by fingerprint)

**Files:**
- Create: `lib/mix/tasks/cash_lens.backfill_statements.ex`
- Modify: `lib/cash_lens/credit_cards.ex` (add `backfill_from_parsed/4`)
- Test: `test/cash_lens/credit_cards_backfill_test.exs`

**Interfaces:**
- Produces:
  - `CreditCards.backfill_file(account, parsed_transactions, meta, source_file) :: {:ok, Statement.t()}`
    - creates a statement, then for each parsed row computes its fingerprint the same way the importer does and `update_all`s the matching existing transaction's `import_batch_id` to the new statement id — **only** `import_batch_id`, never category. Then calls `Matcher.auto_link/2`.
  - Mix task `cash_lens.backfill_statements` iterates the `.account` folder structure (reuse `CashLens.Parsers.DirectoryImporter` account resolution) and calls `backfill_file/4` per file.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CashLens.CreditCardsBackfillTest do
  use CashLens.DataCase, async: true

  test "backfill_file stamps existing rows by fingerprint without touching category" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    cat = CashLens.CategoriesFixtures.category_fixture(%{name: "Food", slug: "food"})

    existing = CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id, amount: Decimal.new("10.00"),
      description: "UBER", date: ~D[2026-06-02], category_id: cat.id
    })

    parsed = [%{description: "UBER", amount: Decimal.new("10.00"), date: ~D[2026-06-02]}]
    meta = %{due_date: ~D[2026-06-15], total_a_pagar: Decimal.new("10.00"), competencia: ~D[2026-06-01]}

    {:ok, statement} = CashLens.CreditCards.backfill_file(card, parsed, meta, "fatura.pdf")

    reloaded = CashLens.Repo.get!(CashLens.Transactions.Transaction, existing.id)
    assert reloaded.import_batch_id == statement.id
    assert reloaded.category_id == cat.id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/credit_cards_backfill_test.exs`
Expected: FAIL — `backfill_file/4` undefined.

- [ ] **Step 3: Implement `backfill_file/4`**

Add to `lib/cash_lens/credit_cards.ex` (compute fingerprints with the same helper the importer uses — occurrence index within the file, mirroring `assign_occurrence_indices`):

```elixir
  alias CashLens.Transactions.Transaction

  def backfill_file(account, parsed_transactions, meta, source_file) do
    {:ok, statement} =
      create_statement(%{
        account_id: account.id,
        due_date: meta.due_date,
        total_a_pagar: meta.total_a_pagar,
        competencia: meta.competencia,
        source_file: source_file
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    parsed_transactions
    |> with_occurrence_indices(account.id)
    |> Enum.each(fn {data, index} ->
      fp = fingerprint_for(data, account.id, index)

      from(t in Transaction, where: t.fingerprint == ^fp)
      |> Repo.update_all(set: [import_batch_id: statement.id, updated_at: now])
    end)

    line_total =
      parsed_transactions
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))

    CashLens.CreditCards.Matcher.auto_link(statement, line_total)
    {:ok, statement}
  end

  defp with_occurrence_indices(parsed, account_id) do
    {tagged, _seen} =
      Enum.map_reduce(parsed, %{}, fn data, seen ->
        key = data |> Map.put(:account_id, account_id) |> Transaction.dedup_key()
        index = Map.get(seen, key, 0)
        {{data, index}, Map.put(seen, key, index + 1)}
      end)

    tagged
  end

  defp fingerprint_for(data, account_id, index) do
    data
    |> Map.put(:account_id, account_id)
    |> Map.put(:occurrence_index, index)
    |> Transaction.fingerprint()
  end
```

Note: verify the exact public name/arity of the fingerprint helper on `Transaction` (`fingerprint/1` vs `fingerprint/2`) and the map shape it expects; mirror exactly what `Ingestor.prepare_transaction_entry/5` produces so fingerprints match stored rows.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/credit_cards_backfill_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the mix task**

```elixir
defmodule Mix.Tasks.CashLens.BackfillStatements do
  use Mix.Task
  @shortdoc "Re-reads credit-card statement files and stamps import_batch_id"

  @moduledoc """
      mix cash_lens.backfill_statements <caminho>

  Defaults <caminho> to the saved `last_batch_import_path`. Re-parses each
  credit-card account's files and stamps matching existing transactions with
  a per-file statement id. Categories are never modified.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    path =
      case args do
        [p | _] -> p
        [] -> CashLens.Settings.get("last_batch_import_path", "")
      end

    CashLens.Parsers.DirectoryImporter.each_credit_card_file(path, fn account, content, file_path ->
      meta =
        if String.ends_with?(file_path, ".pdf"),
          do: CashLens.Parsers.PDFParser.extract_statement_meta(content),
          else: %{due_date: nil, total_a_pagar: nil, competencia: nil}

      parsed = CashLens.Parsers.Ingestor.parse(content, account.parser_type)
      CashLens.CreditCards.backfill_file(account, parsed, meta, Path.basename(file_path))
    end)

    Mix.shell().info("Backfill complete.")
  end
end
```

Note: if `DirectoryImporter` has no `each_credit_card_file/2` helper, add a small one there that walks the same `.account` folders `import_directory` uses, filters to `is_credit_card` accounts, reads+prepares each file's content, and yields `(account, content, file_path)`. Reuse the existing content preparation (PDF text extraction) so parsing matches import.

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/cash_lens.backfill_statements.ex lib/cash_lens/credit_cards.ex lib/cash_lens/parsers/directory_importer.ex test/cash_lens/credit_cards_backfill_test.exs
git commit -m "feat(mix): backfill_statements re-reads files and stamps import_batch_id"
```

---

### Task 10: LiveView — overview table + detail + route/nav

**Files:**
- Create: `lib/cash_lens_web/live/credit_card_statement_live/index.ex`
- Modify: `lib/cash_lens_web/router.ex`
- Modify: `lib/cash_lens_web/components/layouts/app.html.heex` (nav href)
- Test: `test/cash_lens_web/live/credit_card_statement_live_test.exs`

**Interfaces:**
- Consumes: `CreditCards.list_statements/0`, `get_statement_detail/1`, `link_payment/2`, `unlink_payment/1`, `suggest_payment/1`.
- Produces: LiveView at `/statements` (overview: filterable table; detail: `?id=` selects a statement) with `link`, `unlink`, `select`, `filter` events. Old `/credit_card_links` redirects to `/statements`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CashLensWeb.CreditCardStatementLiveTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest
  import CashLens.CreditCardsFixtures

  test "overview lists statements", %{conn: conn} do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, name: "Ourocard"})
    statement_fixture(%{account: account})

    {:ok, _view, html} = live(conn, ~p"/statements")
    assert html =~ "Ourocard"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens_web/live/credit_card_statement_live_test.exs`
Expected: FAIL — route/module missing.

- [ ] **Step 3: Add the route + redirect + nav**

In `lib/cash_lens_web/router.ex`, replace the `/credit_card_links` line with:

```elixir
      live "/statements", CreditCardStatementLive.Index, :index
      get "/credit_card_links", RedirectController, :statements
```

Add a tiny redirect (or use `Phoenix.Router.get "/credit_card_links", ...` → a controller that `redirect(conn, to: ~p"/statements")`). In `app.html.heex`, change the nav `href="/credit_card_links"` to `href="/statements"` (keep the "Cartão de Crédito" label and `hero-credit-card` icon).

- [ ] **Step 4: Implement the LiveView**

Build `CreditCardStatementLive.Index` with:
- `mount/3`: `assign(:statements, CreditCards.list_statements())`, `assign(:filter, %{account_id: nil, only_open: false})`, `assign(:selected, nil)`.
- `handle_params/3`: if `id` present, `assign(:selected, CreditCards.get_statement_detail(id))` and `assign(:suggestion, CreditCards.suggest_payment(detail.statement))`; else clear.
- `handle_event("filter", …)`: update filter, re-derive shown rows.
- `handle_event("link", %{"payment-id" => pid}, …)`: `link_payment` then reload + flash.
- `handle_event("unlink", …)`: `unlink_payment` then reload + flash.
- `render/1`: overview = filter chips (all / per account / "só abertas") + a single table (Cartão · Competência · Vence · Total · Status badge), each row `phx-click` navigates to `?id=`. Detail = header (card, competência, vencimento, source_file, total_a_pagar with line_total beneath), a payment band (green linked w/ Desvincular, or amber open w/ suggestion "Vincular"/"Escolher…"), then the transactions table. Reuse `format_currency/1` and daisyUI classes from the old `CreditCardLinkLive.Index` render for visual consistency.

Status badge mapping: `:linked` → green ✅, `:open` → amber ⚠, `:divergent` → red ❗.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/cash_lens_web/live/credit_card_statement_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens_web/live/credit_card_statement_live/ lib/cash_lens_web/router.ex lib/cash_lens_web/components/layouts/app.html.heex test/cash_lens_web/live/credit_card_statement_live_test.exs
git commit -m "feat(web): statement overview + detail LiveView"
```

---

### Task 11: Remove the old reconciliation code

**Files:**
- Delete: `lib/cash_lens_web/live/credit_card_link_live/index.ex`
- Delete: `lib/cash_lens/transactions/credit_card_matcher.ex`
- Modify: `lib/cash_lens/transactions.ex` (remove now-dead functions)
- Modify: `lib/cash_lens/parsers/ingestor.ex` (drop `CreditCardMatcher` alias)
- Delete/replace: `test/cash_lens/transactions/credit_card_matcher_test.exs` and old LiveView test

**Interfaces:**
- Consumes: nothing new.
- Produces: no references to `CreditCardMatcher`, `CreditCardLinkLive`, or the old `list_credit_card_*` batch/suggestion functions remain.

- [ ] **Step 1: Find all references**

Run: `grep -rn "CreditCardMatcher\|CreditCardLinkLive\|list_credit_card_orphan_batches\|list_credit_card_link_suggestions\|list_credit_card_payment_candidates\|list_credit_card_payments_without_children\|link_credit_card_batch\|unlink_credit_card_children\|list_credit_card_divergent_links\|list_credit_card_linked" lib test`
Expected: a list of call sites to clean.

- [ ] **Step 2: Delete the old modules and dead context functions**

Remove `credit_card_matcher.ex`, `credit_card_link_live/index.ex`, and the listed `list_credit_card_*` / `link_credit_card_batch` / `unlink_credit_card_children` functions from `transactions.ex` (and their private helpers `linked_parent_ids_subquery`, `unlinked_credit_card_payments`, etc. if now unused). Remove the `alias ... CreditCardMatcher` and the old `match_batch` call site (already replaced in Task 8). Delete the old matcher test and old LiveView test.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS with no compile warnings about undefined functions.

- [ ] **Step 4: Format and credo**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(credit-card): remove old inserted_at-based reconciliation"
```

---

## Self-Review

**Spec coverage:**
- Data model (`credit_card_statements` + `import_batch_id`) → Tasks 1, 2.
- Parser (due date reuse + total extraction) → Task 7.
- Import (UUID per file, create statement, stamp, match by statement) → Task 8.
- Matching (auto-link exact within ~15-day window; else suggestion) → Tasks 5 (suggest), 6 (auto-link).
- Backfill (re-read by fingerprint, categories intact, idempotent, then match) → Task 9.
- UI (overview table filterable = option B; detail with payment band on top = option 1; status badges) → Task 10.
- Route rename `/credit_card_links` → `/statements` with redirect → Task 10.
- Cleanup of old reconciliation code → Task 11.

**Placeholder scan:** Task 8 and 9 tests intentionally defer to existing import fixtures / the exact fingerprint helper arity — flagged with concrete "verify X" notes rather than silent TODOs, because those depend on repo details the implementer must confirm at the file. All other steps carry complete code.

**Type consistency:** `auto_link(statement, line_total)` used identically in Tasks 6, 8, 9. `link_payment/2`, `unlink_payment/1`, `suggest_payment/1`, `statement_status/2`, `list_statements/0`, `get_statement_detail/1`, `extract_statement_meta/1`, `backfill_file/4` names are consistent across tasks. `import_batch_id` is the statement id everywhere.
