# Ourocard TXT Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Ourocard OFX import with a BB TXT parser that yields real Vencimento + total, and migrate the account cleanly.

**Architecture:** A new `OurocardTXTParser` parses the plain-text BB statement: every line starting with a `DD.MM.YYYY` date is a transaction (everything else is ignored); the header yields due date + total. It plugs into the existing `Ingestor` dispatch and `statement_meta/2`, and `.txt` becomes a routable extension. A one-time migration mix task wipes the Ourocard OFX data and switches the account's parser.

**Tech Stack:** Elixir 1.18, Ecto/Postgres, ExUnit. Amounts are `Decimal`.

## Global Constraints

- Transaction map shape must match the other parsers: `%{date: Date.t(), description: String.t(), amount: Decimal.t(), time: Time.t() | nil}`.
- A line is a transaction **iff** it starts with `DD.MM.YYYY`. No exclusion lists.
- Sign inversion: stored `amount = Decimal.negate(txt_value)` (TXT purchases are positive, credits negative; app uses purchases negative, credits positive).
- BR number format: values look like `11.938,58` / `-14.391,19` (`.` = thousands, `,` = decimal).
- `description`: collapse runs of whitespace to a single space, then trim (same as `OFXParser.clean_description/1`).
- `total_a_pagar` is stored **positive** (it's the bill amount).
- Content reaches parsers already UTF-8 (the ingestor's `prepare_content/3` runs `ensure_utf8` on non-PDF files); parsers do not re-encode.
- Money compared with `Decimal.equal?/2`, never `==`.

---

### Task 1: OurocardTXTParser — transaction parsing

**Files:**
- Create: `lib/cash_lens/parsers/ourocard_txt_parser.ex`
- Test: `test/cash_lens/parsers/ourocard_txt_parser_test.exs`

**Interfaces:**
- Produces: `CashLens.Parsers.OurocardTXTParser.parse(content, format \\ :ourocard) :: [%{date, description, amount, time}]`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CashLens.Parsers.OurocardTXTParserTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.OurocardTXTParser

  @sample """
                           Fatura do Cartão de Crédito
  Vencimento      : 16.07.2026
  Total da fatura : R$ 11.938,58

  Data     Transações                             País        Valor R$   Valor US$
  --------------------------------------------------------------------------------
           1 - HEITOR L POLIDORO

           SALDO FATURA ANTERIOR                  BR         14.391,19        0,00

           Pagamentos/Créditos
  16.06.2026PGTO DEBITO CONTA 5899 000009516  200211          -14.391,19        0,00

           Educação
  15.06.2026SCHOOL OF ROCK         SAO JOSE DOS  BR              537,82        0,00
  23.01.2026KIPLING       PARC 05/06 SAO JOSE DOSBR              183,16        0,00
           SubTotal                                           7.827,48        0,00
           Total                                             11.938,58        0,00
  """

  test "parses only dated lines, inverts sign, cleans description" do
    txns = OurocardTXTParser.parse(@sample, :ourocard)

    # 3 dated lines: the payment credit + 2 purchases. SALDO ANTERIOR/SubTotal/
    # Total/headers/labels have no leading date and are ignored.
    assert length(txns) == 3

    pay = Enum.find(txns, &(&1.date == ~D[2026-06-16]))
    assert pay.description == "PGTO DEBITO CONTA 5899 000009516 200211"
    assert Decimal.equal?(pay.amount, Decimal.new("14391.19"))

    rock = Enum.find(txns, &(&1.date == ~D[2026-06-15]))
    assert rock.description == "SCHOOL OF ROCK SAO JOSE DOS BR"
    assert Decimal.equal?(rock.amount, Decimal.new("-537.82"))

    kipling = Enum.find(txns, &String.contains?(&1.description, "KIPLING"))
    assert kipling.description == "KIPLING PARC 05/06 SAO JOSE DOSBR"
    assert Decimal.equal?(kipling.amount, Decimal.new("-183.16"))
    assert kipling.time == nil
  end

  test "returns [] when there are no dated lines" do
    assert OurocardTXTParser.parse("Vencimento : 16.07.2026\nTotal da fatura : R$ 1,00", :ourocard) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ourocard_txt_parser_test.exs`
Expected: FAIL — `OurocardTXTParser` undefined.

- [ ] **Step 3: Implement the parser**

```elixir
defmodule CashLens.Parsers.OurocardTXTParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Parser for Banco do Brasil Ourocard credit-card statements in plain-text
  (.txt) form. A line is a transaction iff it starts with a `DD.MM.YYYY`
  date; every other line (headers, category/holder labels, SALDO ANTERIOR,
  SubTotal, Total, separators) lacks a leading date and is skipped.
  """

  # date (glued to the description) · description · Valor R$ · Valor US$
  @line_regex ~r/^(\d{2})\.(\d{2})\.(\d{4})(.+?)\s+(-?[\d.]+,\d{2})\s+-?[\d.]+,\d{2}\s*$/

  @impl true
  def parse(content, _format \\ :ourocard) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    case Regex.run(@line_regex, line) do
      [_, d, m, y, desc, value] ->
        with {:ok, date} <-
               Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)),
             amount when not is_nil(amount) <- parse_amount(value) do
          [%{date: date, description: clean_description(desc), amount: Decimal.negate(amount), time: nil}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp clean_description(desc) do
    desc |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # BR format: "11.938,58" -> remove thousands ".", decimal "," -> "."
  defp parse_amount(str) do
    cleaned = str |> String.replace(".", "") |> String.replace(",", ".")

    case Decimal.parse(cleaned) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ourocard_txt_parser_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/parsers/ourocard_txt_parser.ex test/cash_lens/parsers/ourocard_txt_parser_test.exs
git commit -m "feat(parser): Ourocard TXT transaction parser"
```

---

### Task 2: OurocardTXTParser — statement metadata

**Files:**
- Modify: `lib/cash_lens/parsers/ourocard_txt_parser.ex`
- Test: `test/cash_lens/parsers/ourocard_txt_parser_test.exs`

**Interfaces:**
- Consumes: the module from Task 1.
- Produces: `OurocardTXTParser.extract_statement_meta(content) :: %{due_date: Date.t() | nil, total_a_pagar: Decimal.t() | nil, competencia: Date.t() | nil}` (same shape as `PDFParser.extract_statement_meta/1` and `OFXParser.extract_statement_meta/1`).

- [ ] **Step 1: Write the failing test**

```elixir
describe "extract_statement_meta/1" do
  test "pulls Vencimento, Total da fatura and competência" do
    meta = OurocardTXTParser.extract_statement_meta(@sample)
    assert meta.due_date == ~D[2026-07-16]
    assert Decimal.equal?(meta.total_a_pagar, Decimal.new("11938.58"))
    assert meta.competencia == ~D[2026-07-01]
  end

  test "degrades to nils when the fields are absent" do
    meta = OurocardTXTParser.extract_statement_meta("no relevant lines")
    assert meta.due_date == nil
    assert meta.total_a_pagar == nil
    assert meta.competencia == nil
  end
end
```

(Add inside the existing test module from Task 1, which already binds `@sample`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ourocard_txt_parser_test.exs`
Expected: FAIL — `extract_statement_meta/1` undefined.

- [ ] **Step 3: Implement**

Add to `lib/cash_lens/parsers/ourocard_txt_parser.ex`:

```elixir
  @doc """
  Statement-level metadata from the TXT header: due date (Vencimento), total
  (Total da fatura, stored positive) and competência (first day of the due
  month). Any field is nil when its line is absent.
  """
  def extract_statement_meta(content) do
    due = extract_due_date(content)

    %{
      due_date: due,
      total_a_pagar: extract_total(content),
      competencia: due && Date.beginning_of_month(due)
    }
  end

  defp extract_due_date(content) do
    case Regex.run(~r/Vencimento\s*:\s*(\d{2})\.(\d{2})\.(\d{4})/i, content) do
      [_, d, m, y] ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_total(content) do
    case Regex.run(~r/Total da fatura\s*:\s*R\$\s*([\d.]+,\d{2})/i, content) do
      [_, value] -> parse_amount(value)
      _ -> nil
    end
  end
```

(`parse_amount/1` already exists from Task 1; the total is positive, no negation.)

- [ ] **Step 4: Run test to verify it passes**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ourocard_txt_parser_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/parsers/ourocard_txt_parser.ex test/cash_lens/parsers/ourocard_txt_parser_test.exs
git commit -m "feat(parser): Ourocard TXT statement metadata"
```

---

### Task 3: Wire the TXT parser into ingestion and routing

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex` (`parse/2`, `expected_extensions/1`, `statement_meta/2`)
- Modify: `lib/cash_lens/parsers/directory_importer.ex` (`@supported_extensions`)
- Test: `test/cash_lens/parsers/ingestor_test.exs`

**Interfaces:**
- Consumes: `OurocardTXTParser.parse/2`, `OurocardTXTParser.extract_statement_meta/1`.
- Produces: `Ingestor.parse(content, "ourocard_txt")` routes to the TXT parser; `Ingestor.expected_extensions("ourocard_txt") == [".txt"]`; `Ingestor.statement_meta(content, "x.txt")` returns the TXT meta; `.txt` is a supported directory-import extension.

- [ ] **Step 1: Write the failing test**

```elixir
test "parse/2 routes ourocard_txt to the TXT parser" do
  content = """
  Vencimento      : 16.07.2026
  Total da fatura : R$ 537,82
  15.06.2026SCHOOL OF ROCK         SAO JOSE DOS  BR              537,82        0,00
  """

  [tx] = CashLens.Parsers.Ingestor.parse(content, "ourocard_txt")
  assert tx.date == ~D[2026-06-15]
  assert Decimal.equal?(tx.amount, Decimal.new("-537.82"))
end

test "expected_extensions and statement_meta handle ourocard_txt/.txt" do
  assert CashLens.Parsers.Ingestor.expected_extensions("ourocard_txt") == [".txt"]

  content = "Vencimento : 16.07.2026\nTotal da fatura : R$ 10,00\n"
  meta = CashLens.Parsers.Ingestor.statement_meta(content, "OUROCARD-Jul_26.txt")
  assert meta.due_date == ~D[2026-07-16]
  assert Decimal.equal?(meta.total_a_pagar, Decimal.new("10.00"))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: FAIL — `ourocard_txt` not routed; `.txt` not in `statement_meta`.

- [ ] **Step 3: Implement the wiring**

In `lib/cash_lens/parsers/ingestor.ex`:

Add an alias near the other parser aliases:
```elixir
  alias CashLens.Parsers.OurocardTXTParser
```

Add a clause to `parse/2` (next to the `ourocard_ofx` clause):
```elixir
      "ourocard_txt" ->
        Logger.info("Using Ourocard TXT Parser")
        OurocardTXTParser.parse(content, :ourocard)
```

Add to `expected_extensions/1`:
```elixir
      "ourocard_txt" -> [".txt"]
```

Extend `statement_meta/2`'s `cond` (from Task 8 of the credit-card work):
```elixir
  def statement_meta(content, file_path) do
    cond do
      String.ends_with?(file_path, ".pdf") -> PDFParser.extract_statement_meta(content)
      String.ends_with?(file_path, ".ofx") -> OFXParser.extract_statement_meta(content)
      String.ends_with?(file_path, ".txt") -> OurocardTXTParser.extract_statement_meta(content)
      true -> %{due_date: nil, total_a_pagar: nil, competencia: nil}
    end
  end
```

In `lib/cash_lens/parsers/directory_importer.ex`, add `.txt` to supported extensions:
```elixir
  @supported_extensions ~w(.csv .ofx .pdf .txt)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/parsers/ingestor_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `export $(cat .env | xargs) && mix test`
Expected: PASS (no regressions from adding `.txt` routing).

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens/parsers/ingestor.ex lib/cash_lens/parsers/directory_importer.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "feat(ingestor): route ourocard_txt and .txt statement metadata"
```

---

### Task 4: Migration mix task (wipe OFX data, switch parser)

**Files:**
- Create: `lib/mix/tasks/cash_lens.migrate_ourocard_txt.ex`
- Modify: `lib/cash_lens/credit_cards.ex` (add `reset_account_statements/1`)
- Test: `test/cash_lens/credit_cards_test.exs`

**Interfaces:**
- Consumes: `CashLens.Accounts`, `CashLens.CreditCards`.
- Produces: `CreditCards.reset_account_statements(account_id) :: {deleted_statements :: non_neg_integer(), deleted_transactions :: non_neg_integer()}` — deletes the account's `credit_card_statements` and its `transactions`. Mix task `cash_lens.migrate_ourocard_txt` resets each `ourocard_ofx` account and switches its `parser_type` to `"ourocard_txt"`.

- [ ] **Step 1: Write the failing test**

```elixir
test "reset_account_statements deletes the account's transactions and statements" do
  card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  other = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
  s = CashLens.CreditCardsFixtures.statement_fixture(%{account: card})
  CashLens.TransactionsFixtures.transaction_fixture(%{account_id: card.id, import_batch_id: s.id})
  keep = CashLens.CreditCardsFixtures.statement_fixture(%{account: other})

  {stmts, txns} = CashLens.CreditCards.reset_account_statements(card.id)
  assert stmts == 1
  assert txns == 1

  assert CashLens.Repo.aggregate(
           from(t in CashLens.Transactions.Transaction, where: t.account_id == ^card.id),
           :count
         ) == 0

  # other account untouched
  assert CashLens.CreditCards.get_statement!(keep.id).id == keep.id
end
```

(Add `import Ecto.Query` to the test file if not already imported.)

- [ ] **Step 2: Run test to verify it fails**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: FAIL — `reset_account_statements/1` undefined.

- [ ] **Step 3: Implement the helper**

Add to `lib/cash_lens/credit_cards.ex`:

```elixir
  @doc """
  Wipes a credit-card account's imported data ahead of a clean re-import:
  deletes its `credit_card_statements` and all its `transactions`. Returns
  `{deleted_statements, deleted_transactions}`.
  """
  def reset_account_statements(account_id) do
    {stmts, _} =
      from(s in Statement, where: s.account_id == ^account_id) |> Repo.delete_all()

    {txns, _} =
      from(t in Transaction, where: t.account_id == ^account_id) |> Repo.delete_all()

    {stmts, txns}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export $(cat .env | xargs) && mix test test/cash_lens/credit_cards_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the mix task**

```elixir
defmodule Mix.Tasks.CashLens.MigrateOurocardTxt do
  use Mix.Task
  import Ecto.Query
  @shortdoc "Wipes ourocard_ofx accounts and switches them to the TXT parser"

  @moduledoc """
      mix cash_lens.migrate_ourocard_txt

  One-time migration: for every account with parser_type "ourocard_ofx",
  deletes its statements and transactions and sets parser_type to
  "ourocard_txt". After running this, delete the account's .ofx files, drop
  the re-exported .txt files in its folder, then re-import + backfill.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    accounts =
      from(a in CashLens.Accounts.Account, where: a.parser_type == "ourocard_ofx")
      |> CashLens.Repo.all()

    Enum.each(accounts, fn account ->
      {stmts, txns} = CashLens.CreditCards.reset_account_statements(account.id)

      {:ok, _} =
        account
        |> CashLens.Accounts.Account.changeset(%{parser_type: "ourocard_txt"})
        |> CashLens.Repo.update()

      Mix.shell().info(
        "#{account.name}: deleted #{stmts} statements, #{txns} transactions; parser -> ourocard_txt"
      )
    end)

    Mix.shell().info("Done. Now: delete .ofx files, add .txt files, then import + backfill.")
  end
end
```

- [ ] **Step 6: Verify it compiles clean and commit**

Run: `export $(cat .env | xargs) && mix compile --warnings-as-errors`
Expected: zero warnings.

```bash
mix format
git add lib/mix/tasks/cash_lens.migrate_ourocard_txt.ex lib/cash_lens/credit_cards.ex test/cash_lens/credit_cards_test.exs
git commit -m "feat(mix): migrate_ourocard_txt resets account and switches parser"
```

---

## Post-implementation (operational — run by the assistant, not a task)

After the branch is merged and the user has re-exported all Ourocard months as `.txt`:

1. `mix cash_lens.migrate_ourocard_txt` (wipes OFX data, switches parser).
2. Delete the Ourocard `.ofx` files from the folder.
3. Re-import the folder (existing import flow) + `mix cash_lens.backfill_statements`.
4. **Gap check:** list the resulting Ourocard competências in order and report any missing month in the sequence, so the user can spot a statement they forgot to export.

## Self-Review

**Spec coverage:**
- Parser + "date-line = transaction" rule + sign inversion + description clean + BR decimals → Task 1.
- `extract_statement_meta` (Vencimento, Total da fatura, competência) → Task 2.
- Ingestor `parse`/`expected_extensions`/`statement_meta` + DirectoryImporter `.txt` → Task 3.
- Migration (wipe + parser switch) → Task 4; file deletion + reimport + gap check → operational section.

**Placeholder scan:** none — every step carries complete code. The operational section is deliberately manual (destructive, data-dependent) and not a coded task.

**Type consistency:** `parse/2`, `extract_statement_meta/1`, `statement_meta/2`, `reset_account_statements/1` names/shapes are consistent across tasks; transaction map shape matches the OFX parser's `%{date, description, amount, time}`; `parse_amount/1` defined in Task 1 reused in Task 2.
