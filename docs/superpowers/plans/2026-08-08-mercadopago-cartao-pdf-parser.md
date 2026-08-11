# Mercado Pago Credit-Card PDF Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `mercadopago_cartao_pdf` parser so the "Mercado Pago - Cartão de Crédito" account's PDF faturas can be imported like every other credit-card account.

**Architecture:** A new `PDFParser.parse(text, :mercado_pago_card)` clause walks the `pdftotext -layout`-converted text as a section-tracking reduce (payment-line section vs. purchases section, switched by two distinct header lines), reusing the module's existing date-resolution and amount-parsing helpers. `Ingestor` and `AccountFile` get one new dispatch entry each. `extract_statement_meta/1`'s total-extraction gets a new, separately-scoped code path for Mercado Pago's format — the *existing* Bradesco-oriented regex is left completely untouched, because Mercado Pago's fatura contains a decoy "Total da fatura de \<mês anterior\>" line that the existing regex would otherwise match instead of the real total.

**Tech Stack:** Elixir, regex-based text parsing, ExUnit.

## Global Constraints

- The "Movimentações na fatura" line imports as a positive (credit) transaction — no `category_id` is set by the parser (matches every other credit-card parser; categorization happens afterward, same as today).
- Every "Cartão Visa [...]" row imports as a negative (debit) transaction.
- A `Parcela N de M` column becomes a `" PARC N/M"` suffix on the description (e.g. `"MERCADOLIVRE*7PRODUTOS PARC 5/7"`), so `CashLens.Transactions.InstallmentDetector`'s existing `\bPARC\s+(\d{1,2})\/(\d{1,2})\b` marker picks it up unchanged. A row with no `Parcela` column keeps its description exactly as extracted.
- Date year resolution reuses `PDFParser.resolve_purchase_date/2` unchanged (no new date logic).
- `PDFParser.extract_total/1` (the function `sem_parar_pdf`/`bradesco_cartao_pdf` rely on) must not change at all — zero risk of regressing those formats.
- The parser identifier is `mercadopago_cartao_pdf`; the internal `PDFParser.parse/2` dispatch atom is `:mercado_pago_card`.

---

### Task 1: `mercadopago_cartao_pdf` parser, wired end to end

**Files:**
- Modify: `lib/cash_lens/parsers/pdf_parser.ex`
- Modify: `lib/cash_lens/parsers/ingestor.ex`
- Modify: `lib/cash_lens/parsers/account_file.ex`
- Test: `test/cash_lens/parsers/pdf_parser_test.exs`
- Test: `test/cash_lens/parsers/account_file_test.exs` (create if it doesn't already exist — check first; if it exists, add to it)
- Test: `test/cash_lens/parsers/ingestor_test.exs` (check first the same way)

**Interfaces:**
- Produces: `CashLens.Parsers.PDFParser.parse(text, :mercado_pago_card)` — returns `[%{date: Date.t(), time: nil, description: String.t(), amount: Decimal.t()}]`, the same shape every other `PDFParser.parse/2` clause returns.
- Produces: `"mercadopago_cartao_pdf"` as a recognized value everywhere `"bradesco_cartao_pdf"` already is (Ingestor dispatch, `expected_extensions/1`, `AccountFile.valid_parsers/0`).
- Consumes (unchanged, already exist in `pdf_parser.ex`): `resolve_purchase_date/2`, `parse_amount/1`, `extract_statement_date/1`.

- [ ] **Step 1: Write the failing parser tests**

Add this new `describe` block to `test/cash_lens/parsers/pdf_parser_test.exs`, right after the existing `describe "parse/2 (bradesco_card)" do ... end` block (i.e. after line 284, before `describe "extract_statement_meta/1" do`):

```elixir
  describe "parse/2 (mercado_pago_card)" do
    test "parses the payment line, every purchase row, and normalizes Parcela to PARC N/M" do
      # Real fatura text (pdftotext -layout output), trimmed to the
      # "Detalhes de consumo" section onward — the marketing/informational
      # pages before and after it don't affect parsing and are omitted.
      text = """
      Detalhes de consumo

      Movimentações na fatura

      Data      Movimentações                                            Valor em R$


      17/06     Pagamento da fatura de junho/2026                         R$ 1.412,10



      Cartão Visa [************8978]

      Data      Movimentações                                            Valor em R$


      27/02     MERCADOLIVRE*7PRODUTOS              Parcela 5 de 7         R$ 22,65


      02/04     MERCADOLIVRE*26PRODUTOS             Parcela 9 de 12        R$ 42,44


      22/04     MERCADOLIVRE*4PRODUTOS               Parcela 3 de 7         R$ 22,14


      24/04     MERCADOLIVRE*3PRODUTOS              Parcela 3 de 10         R$ 41,29


      29/04     MERCADOLIVRE*MERCADOLIVRE           Parcela 3 de 5          R$ 13,44


      12/05     MERCADOLIVRE*MCUTILIDADES           Parcela 2 de 4          R$ 8,40


      02/06     MERCADOLIVRE*MERCADOLI              Parcela 2 de 5          R$ 15,56


      02/06     MERCADOLIVRE*MERCADOLI              Parcela 2 de 8         R$ 42,57


      06/06     MERCADOLIVRE*MASTERREMOTE           Parcela 2 de 6          R$ 19,99


      16/06     MERCADOLIVRE*MERCADOLIVRE                                   R$ 76,75


      21/06     MERCADOLIVRE*MERCADOLIVRE           Parcela 1 de 12        R$ 48,50


      21/06     MERCADOLIVRE*MERCADOLIVRE                                  R$ 301,67


      25/06     MERCADOLIVRE*MERCADOLI                                    R$ 402,60
                                               Heitor Luis Polidoro
                                            Vencimento: 17/07/2026


      Cartão Visa [************8978]

      Data      Movimentações                          Valor em R$


      25/06     MERCADOLIVRE*MERCADOLIVRE                R$ 201,41


      06/07     MERCADOLIVRE*MERCADOLI                   R$ 98,54

      Total                                             R$ 1.357,95
      """

      transactions = PDFParser.parse(text, :mercado_pago_card)

      assert length(transactions) == 16

      payment = Enum.find(transactions, &(&1.description =~ "Pagamento da fatura"))
      assert payment.description == "Pagamento da fatura de junho/2026"
      assert payment.amount == Decimal.new("1412.10")
      assert payment.date == ~D[2026-06-17]

      installment = Enum.find(transactions, &(&1.description =~ "7PRODUTOS"))
      assert installment.description == "MERCADOLIVRE*7PRODUTOS PARC 5/7"
      assert installment.amount == Decimal.new("-22.65")
      assert installment.date == ~D[2026-02-27]

      plain = Enum.find(transactions, &(&1.amount == Decimal.new("-76.75")))
      assert plain.description == "MERCADOLIVRE*MERCADOLIVRE"
      assert plain.date == ~D[2026-06-16]

      # Row from the page-3 continuation of the same "Cartão Visa" table —
      # proves the section-tracking survives the repeated page header.
      continuation = Enum.find(transactions, &(&1.amount == Decimal.new("-201.41")))
      assert continuation.description == "MERCADOLIVRE*MERCADOLIVRE"
      assert continuation.date == ~D[2026-06-25]

      purchases_total =
        transactions
        |> Enum.reject(&(&1.description =~ "Pagamento da fatura"))
        |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))

      assert Decimal.equal?(purchases_total, Decimal.new("-1357.95"))
    end

    test "a row with no Parcela column keeps its description unsuffixed" do
      text = """
      Movimentações na fatura

      Cartão Visa [****1234]
      Data      Movimentações                          Valor em R$
      01/03     LOJA SEM PARCELA                        R$ 10,00
      """

      [tx] = PDFParser.parse(text, :mercado_pago_card)
      assert tx.description == "LOJA SEM PARCELA"
      refute tx.description =~ "PARC"
    end
  end
```

- [ ] **Step 2: Write the failing `extract_statement_meta` test**

Add this test inside the existing `describe "extract_statement_meta/1" do ... end` block, after its last test (`"extract_statement_meta degrades to nils when absent"`, before the block's closing `end`):

```elixir
    test "extract_statement_meta on a Mercado Pago fatura ignores the decoy previous-cycle total" do
      # Real fatura text (pdftotext -layout output): note "Total da fatura de
      # junho" (a DIFFERENT, previous-cycle number) appears before the real
      # total — this must not be picked up.
      text = """
      Olá, Heitor Luis
      Essa é sua fatura de julho
      Total a pagar                            Vence em                      Limite total                 Saque total
                                               17/07/2026                    R$ 23.200,00                 R$ 50,00
      R$ 1.357,95

      Informações complementares
      Resumo da fatura

        Consumos de 13/06 a 12/07                               R$ 1.357,95                Juros do mês anterior                                           R$ 0,00

        Tarifas e encargos                                           R$ 0,00               Pagamentos e créditos devolvidos                            R$ 1.412,10

        Multas por atraso                                            R$ 0,00

        Total da fatura de junho                                 R$ 1.412,10


                                                                                            Total                                         R$ 1.357,95

      Heitor Luis Polidoro
      Vencimento: 17/07/2026
      """

      meta = PDFParser.extract_statement_meta(text)

      assert meta.due_date == ~D[2026-07-17]
      assert meta.competencia == ~D[2026-07-01]
      assert Decimal.equal?(meta.total_a_pagar, Decimal.new("1357.95"))
    end
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `mix test test/cash_lens/parsers/pdf_parser_test.exs`
Expected: FAIL — `:mercado_pago_card` isn't a recognized `parse/2` clause yet (`FunctionClauseError`), and the new `extract_statement_meta` test currently gets the wrong total (`1412.10` instead of `1357.95`) since the existing `TOTAL DA FATURA` regex matches the decoy line first — run it and confirm this is the actual failure mode, not just any failure.

- [ ] **Step 4: Add the `:mercado_pago_card` clause to `PDFParser.parse/2`**

In `lib/cash_lens/parsers/pdf_parser.ex`, add this clause immediately after the existing `def parse(text, :bradesco_card) do ... end` clause (which ends around line 34, right before `defp detect_max_width`):

```elixir
  def parse(text, :mercado_pago_card) do
    statement_date = extract_statement_date(text)
    lines = String.split(text, "\n")

    {transactions, _section} =
      Enum.reduce(lines, {[], :none}, fn line, {acc, section} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            {acc, section}

          String.contains?(trimmed, "Movimentações na fatura") ->
            {acc, :payment}

          String.starts_with?(trimmed, "Cartão Visa") ->
            {acc, :purchases}

          section in [:payment, :purchases] ->
            case parse_mercado_pago_line(trimmed, section, statement_date) do
              nil -> {acc, section}
              tx -> {[tx | acc], section}
            end

          true ->
            {acc, section}
        end
      end)

    Enum.reverse(transactions)
  end
```

Add the regex as a module attribute near the top of the module, right after the `@behaviour CashLens.Parsers.Parser` line:

```elixir
  @mercado_pago_line_regex ~r/^(\d{2}\/\d{2})\s+(.+?)(?:\s+Parcela\s+(\d+)\s+de\s+(\d+))?\s+R\$\s*([\d.]+,\d{2})\s*$/
```

Add these four private functions right after the new `parse/2` clause (before `defp detect_max_width`):

```elixir
  defp parse_mercado_pago_line(line, section, statement_date) do
    case Regex.run(@mercado_pago_line_regex, line) do
      [_, date_str, desc, parcela_n, parcela_m, amount_str] ->
        %{
          date: resolve_purchase_date(date_str, statement_date),
          time: nil,
          description: mercado_pago_description(desc, parcela_n, parcela_m),
          amount: mercado_pago_amount(amount_str, section)
        }

      _ ->
        nil
    end
  end

  defp mercado_pago_description(desc, "", ""), do: desc
  defp mercado_pago_description(desc, n, m), do: desc <> " PARC #{n}/#{m}"

  defp mercado_pago_amount(amount_str, :payment), do: parse_amount(amount_str)
  defp mercado_pago_amount(amount_str, :purchases), do: Decimal.negate(parse_amount(amount_str))
```

- [ ] **Step 5: Fix `extract_statement_meta/1`'s total extraction for Mercado Pago, without touching `extract_total/1`**

In `lib/cash_lens/parsers/pdf_parser.ex`, find the existing `extract_statement_meta/1`:

```elixir
  def extract_statement_meta(text) do
    due = extract_statement_date_or_nil(text)

    %{
      due_date: due,
      total_a_pagar: extract_total(text),
      competencia: due && Date.beginning_of_month(due)
    }
  end
```

Change only the `total_a_pagar` line, from `extract_total(text)` to `extract_total_amount(text)`:

```elixir
  def extract_statement_meta(text) do
    due = extract_statement_date_or_nil(text)

    %{
      due_date: due,
      total_a_pagar: extract_total_amount(text),
      competencia: due && Date.beginning_of_month(due)
    }
  end
```

Add these two new private functions right after the existing `extract_total/1` function (do not modify `extract_total/1` itself — leave it exactly as it is):

```elixir
  # Mercado Pago's fatura repeats "Total da fatura de <mês anterior>" (a
  # different month's total) before its own real total — text that
  # `extract_total/1`'s "TOTAL DA FATURA" pattern (built for Bradesco) would
  # otherwise match instead of the real one. Route by a marker unique to
  # Mercado Pago's layout ("Total a pagar", not present in Bradesco's real
  # statements) rather than widening the shared regex to cover both formats
  # unsafely.
  defp extract_total_amount(text) do
    if String.contains?(text, "Total a pagar") do
      extract_mercado_pago_total(text)
    else
      extract_total(text)
    end
  end

  defp extract_mercado_pago_total(text) do
    regex = ~r/Total\s+R\$\s*([\d.]+,\d{2})/

    case Regex.run(regex, text) do
      [_, amount_str] -> parse_amount(amount_str) |> Decimal.abs()
      _ -> nil
    end
  end
```

- [ ] **Step 6: Run the PDF parser tests to verify they pass**

Run: `mix test test/cash_lens/parsers/pdf_parser_test.exs`
Expected: all tests PASS, including the new `mercado_pago_card` and `extract_statement_meta` tests, and every pre-existing test in the file (proving `extract_total/1` and every `:bradesco_card`/`:sem_parar` test is unaffected).

- [ ] **Step 7: Wire up `Ingestor.parse/2` and `expected_extensions/1`**

In `lib/cash_lens/parsers/ingestor.ex`, add this clause immediately after the existing `"bradesco_cartao_pdf" -> ...` clause inside `parse/2` (before the `"standard_ofx" ->` clause):

```elixir
      "mercadopago_cartao_pdf" ->
        Logger.info("Using Mercado Pago Cartao PDF Parser")
        PDFParser.parse(content, :mercado_pago_card)
```

In the same file, find `expected_extensions/1`:

```elixir
      t when t in ["sem_parar_pdf", "bradesco_cartao_pdf"] -> [".pdf"]
```

Change it to:

```elixir
      t when t in ["sem_parar_pdf", "bradesco_cartao_pdf", "mercadopago_cartao_pdf"] -> [".pdf"]
```

- [ ] **Step 8: Register the parser in `AccountFile.valid_parsers/0`**

In `lib/cash_lens/parsers/account_file.ex`, find:

```elixir
  @valid_parsers ~w(bb_csv bradesco_csv mercado_pago_csv standard_ofx ourocard_ofx ourocard_txt sem_parar_pdf bradesco_cartao_pdf)
```

Change it to:

```elixir
  @valid_parsers ~w(bb_csv bradesco_csv mercado_pago_csv standard_ofx ourocard_ofx ourocard_txt sem_parar_pdf bradesco_cartao_pdf mercadopago_cartao_pdf)
```

- [ ] **Step 9: Write tests for the two dispatch points**

First check whether `test/cash_lens/parsers/ingestor_test.exs` and `test/cash_lens/parsers/account_file_test.exs` already exist (`ls test/cash_lens/parsers/`). If a file exists, add the test below into its most relevant existing `describe` block (or a new one if none fits). If it doesn't exist, it's fine either way — these two assertions are small enough to add as standalone tests; match whatever style/imports the existing file (if any) already uses.

For `Ingestor`, an assertion that the new parser type maps to `.pdf`:

```elixir
  test "expected_extensions/1 recognizes mercadopago_cartao_pdf as a PDF parser" do
    assert Ingestor.expected_extensions("mercadopago_cartao_pdf") == [".pdf"]
  end
```

For `AccountFile`, an assertion that it's a valid parser identifier:

```elixir
  test "validate_parser accepts mercadopago_cartao_pdf" do
    assert AccountFile.validate_parser(%{bank: "Mercado Pago", account: "Cartão de Crédito", parser: "mercadopago_cartao_pdf"}) == :ok
  end
```

(Adjust the `alias`/module-reference style to match whichever of the two test files it lands in — e.g. if the file already does `alias CashLens.Parsers.Ingestor`, just call `Ingestor.expected_extensions/1` directly as shown; if not, use the fully qualified `CashLens.Parsers.Ingestor.expected_extensions/1`.)

- [ ] **Step 10: Run the full test suite**

Run: `mix test`
Expected: PASS, with the same pre-existing, unrelated failures as before this change (3 failures in `test/cash_lens_web/live/installment_live_test.exs`, date-sensitive fixtures) — no new failures.

- [ ] **Step 11: Verify against the real fatura file on disk**

Run this to parse the user's actual PDF (already renamed to `2026-07.pdf`) exactly the way the app would, and print the results for inspection:

```bash
mix run -e '
alias CashLens.Parsers.{PDFParser, PDFConverter}

path = "/Users/heitor/Library/CloudStorage/GoogleDrive-heitor.polidoro@gmail.com/My Drive/Banco/Mercado Pago - Cartão de Crédito /2026-07.pdf"
{:ok, text} = PDFConverter.SystemConverter.convert(path)

transactions = PDFParser.parse(text, :mercado_pago_card)
IO.puts("Transaction count: #{length(transactions)}")
Enum.each(transactions, &IO.inspect/1)

meta = PDFParser.extract_statement_meta(text)
IO.inspect(meta, label: "statement meta")
'
```

Expected: 16 transactions printed (1 positive `1412.10` payment + 15 negative purchases summing to `-1357.95`), and `statement meta` showing `due_date: ~D[2026-07-17]`, `total_a_pagar: #Decimal<1357.95>`, `competencia: ~D[2026-07-01]` — matching Task's Step 1/2 test fixtures exactly, now proven against the real file rather than just the pasted-text fixture.

- [ ] **Step 12: Commit**

```bash
git add lib/cash_lens/parsers/pdf_parser.ex lib/cash_lens/parsers/ingestor.ex lib/cash_lens/parsers/account_file.ex test/cash_lens/parsers/
git commit -m "feat(parsers): add mercadopago_cartao_pdf parser for Mercado Pago credit-card faturas"
```

---

## Plan Self-Review Notes

- **Spec coverage:** payment-line-as-credit, purchase-rows-as-debit, Parcela→PARC normalization, date-year resolution reuse, and the `total_a_pagar` decoy-line hazard are each covered by a specific test (Step 1's two tests, Step 2's test). Dispatch wiring (`Ingestor.parse/2`, `expected_extensions/1`, `AccountFile.valid_parsers/0`) is covered by Steps 7–9. The real-file verification in Step 11 closes the loop the spec's own testing section promised ("verified against the real file"). Covered.
- **Type consistency:** the new `parse/2` clause returns the exact same `%{date:, time:, description:, amount:}` shape `:bradesco_card` and `:sem_parar` already return — no new fields introduced, nothing downstream needs to change to consume it (the `Ingestor.import_file/3` pipeline already handles this shape generically).
- **No placeholders:** every step has runnable code or an exact command, including the two dispatch tests in Step 9, which give the actual assertion code rather than describing what to test.
