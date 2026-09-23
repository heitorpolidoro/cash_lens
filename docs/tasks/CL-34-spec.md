# CL-34 — Split the transactions summary into cash and card figures

## Scope

`/transactions` (`CashLensWeb.TransactionLive.Index`) renders, whenever a filter
is active, a strip with `id="filter-summary-card"` headed
`Resumo Financeiro do Filtro`. It prints three figures — `Entradas`
(`@summary.income`), `Saídas` (`@summary.expenses`) and `Balanço Líquido`
(`income - expenses`) — over **all** matching transactions, credit-card accounts
included, plus the caption `{@filtered_count} transações no recorte selecionado`.

Measured on the dev database for 2026-06 (recomputed with the same exclusions
`get_filtered_summary/1` applies):

| account kind | income | expenses | rows |
|---|---|---|---|
| cash (`is_credit_card = false`) | 54 713,34 | 43 504,18 | 72 |
| card (`is_credit_card = true`)  | 19 062,04 | 13 926,95 | 138 |

The card column is not noise. Its 13 926,95 of spending is real card spending,
and its 19 062,04 of positives are overwhelmingly the credits that settle a
bill — which the operator has explicitly ruled out as income. Adding the two
columns, as the strip does today, produces an `Entradas` that claims 19 062,04
of income that never entered any account, and a `Balanço Líquido` built on it.

This task **splits that strip into a cash group and a card group**, so no
displayed figure adds the two.

### The principle this task settles

**List screens show everything; aggregate figures never mix cash with card
debt.** A per-row list is one row per transaction, so nothing is mixed and
credit-card rows belong there. The earlier rule — "every global screen
considers only non-credit-card accounts" — is **withdrawn for list screens**.
It still holds where the aggregate *is* the product: the dashboard and
`/months` (CL-31). `CashLens.Accounts.Scopes` and its existing consumers
(`get_monthly_summary/2`, `get_historical_summary/1`, the transfer queries,
the forecast category suggestions) are untouched by this task.

### Explicitly not in this task — do not restore

Two earlier versions of this spec were written and rejected. None of the
following may appear in the implementation, and a reviewer must treat any of
them as a blocking finding:

- restricting `Transactions.list_transactions/3`, `count_transactions/1` or
  `get_filtered_summary/1` to cash accounts, by default or otherwise;
- any `"cash_accounts_only"` or `"include_credit_cards"` filter key, in this
  context or in the LiveView's filter map;
- removing credit-card accounts from the screen's account `<select>` (it is fed
  by `Accounts.list_accounts/0` and keeps listing every account);
- any note, banner or link pointing the reader at `/statements`.

Also out of scope: the JSON API, `/balances` (CL-35), `/months` (CL-31), the
dashboard, the table body, pagination and the statement health bar.

## Approach

### Behavior

1. **`get_filtered_summary/1` returns the split.** It returns
   `%{cash: %{income: Decimal, expenses: Decimal, count: integer},
     cards: %{income: Decimal, expenses: Decimal, count: integer}}`.
   A row is a card row when its account's `is_credit_card` is `true`; every
   other row, including one whose account row is missing, counts as cash — the
   same predicate and the same default CL-35 uses on `/balances`.
   All existing filters and the existing `exclude_transfer_category/1` exclusion
   keep applying unchanged; the only change is that the aggregate is grouped by
   the account kind instead of collapsed.

2. **The split belongs in the query, not in the LiveView.** The LiveView cannot
   derive it: the strip summarises *all* rows matching the filter, while
   `@streams.transactions` holds only the pages loaded so far, and a stream is
   not re-reducible. The grouping must therefore happen where the aggregation
   already happens — one query, joining the account and grouping by
   `is_credit_card`, with both keys always present (zeroed) when a side has no
   rows, so callers never pattern-match on a missing key.

3. **The strip renders two labelled groups.** Inside the existing
   `#filter-summary-card`, the current three-figure row is replaced by:

   - a group `id="filter-summary-cash"` headed `EM CONTAS`, keeping the three
     existing labels **verbatim**: `Entradas`, `Saídas`, `Balanço Líquido`,
     fed by `@summary.cash` and coloured exactly as today;
   - a group `id="filter-summary-cards"` headed `EM CARTÕES`, with **two**
     figures: `Gastos` (`@summary.cards.expenses`, `text-error`) and
     `Créditos` (`@summary.cards.income`, rendered *neutrally*, not in
     `text-success`), carrying the HTML `title` attribute
     `Estornos e pagamentos de fatura — não são receita`.

4. **No `Balanço Líquido` on the card side.** A card account's positives are
   bill settlements and refunds, not income; subtracting spending from them
   yields a number that describes neither debt incurred nor money earned. The
   operator has already classified those positives as "NÃO É RECEITA". The card
   group therefore reports the two raw movements and stops. This is also why
   `Créditos` is not labelled `Entradas` and is not painted green.

5. **An absent side is omitted, not zeroed.** Each group renders only when its
   own `count > 0` — the rule CL-35 adopted on `/balances`, for the same
   reason: filtering to a credit-card account and being shown
   `Entradas R$ 0,00 / Balanço Líquido R$ 0,00` reads as a claim about the
   filtered money rather than as "no rows of this kind". With a filter active
   and no matching rows at all, the strip renders with neither group, keeping
   its heading and caption.

6. **A Pluggy live-preview entry joins the group its own account belongs to.**
   The strip's figures are not `get_filtered_summary/1`'s output alone:
   `recalculate_summary/1` (index.ex:1144) adds the on-screen live entries via
   `add_live_summary/2` (index.ex:1165-1182), and the mount default
   (index.ex:46) seeds the assign. Both currently build the flat
   `%{income:, expenses:}` shape and **must** be rewritten to the new
   two-group shape. A live entry carries an `account_id` but no
   `is_credit_card`, so the entry's account decides: resolve the account and
   add the entry's amount to `cards` when that account's `is_credit_card` is
   `true`, to `cash` otherwise (including when the account cannot be resolved,
   matching Behavior 1's default). A live entry must also increment its
   group's `count`; otherwise a filter matching only live entries leaves
   `cash.count == 0`, Behavior 5 omits the group, and the live figures vanish
   from the strip while their rows stay visible in the table — exactly the
   regression the comment at index.ex:1140-1143 exists to prevent.
   The live preview is currently disabled by config
   (`config :cash_lens, :pluggy_live_preview_enabled, false`, config.exs:20),
   so this path is dormant in the running app; the code and its tests are
   live and the operator can re-enable it, so it must not silently break.

7. **The caption stays one count.** `{@filtered_count} transações no recorte
   selecionado` describes the table below it, and that table is deliberately
   unified — one row per transaction, cards included. Splitting the caption
   would assert a division the list does not have. `count_transactions/1` is
   not touched.

### Files touched

- `lib/cash_lens/transactions.ex` — `get_filtered_summary/1` groups by the
  account kind and returns the two-map shape; its `@doc` states the new return
  value and that the function is deliberately **not** scoped to cash accounts.
- `lib/cash_lens_web/live/transaction_live/index.html.heex` — the three-figure
  row inside `#filter-summary-card` becomes the two groups described above.
- `lib/cash_lens_web/live/transaction_live/index.ex` — the assign name
  `:summary` stays, but its shape changes everywhere it is produced:
  `calculate_summary/1` (passes the new map through), `add_live_summary/2`
  (index.ex:1165-1182 — adds each live entry's amount, and its count, to the
  group chosen by its account's `is_credit_card`, per Behavior 6) and the
  mount default at index.ex:46 (the zeroed two-group map, both keys present).
- `test/cash_lens/transactions_test.exs` — the existing
  `get_filtered_summary/1` test (around line 829) is updated to the new shape
  and a case covering cash and card rows in one filter is added.
- `test/cash_lens_web/live/transaction_live_test.exs` — the existing test
  "swaps the health bar for the financial summary card when a filter is
  applied" (around line 413) keeps asserting the three verbatim cash labels and
  gains assertions for the card group and for its omission.
- `test/cash_lens_web/live/transaction_live/index_test.exs` — the two existing
  live-preview tests (the entry-rendering test at line 46 and the totals test at
  line 178, whose `assert html =~ "R$ 35,00"` at line 214 pins the summed live
  amount) keep passing, and two cases are added:
  a live entry on a cash account showing inside `#filter-summary-cash`, and one
  on a credit-card account showing inside `#filter-summary-cards`.

### Test criteria

- Given one cash transaction and one card transaction matching the same filter,
  `get_filtered_summary/1` puts each in its own map and no returned figure is
  the sum of both.
- With a filter matching only cash rows, `#filter-summary-cards` is absent from
  the rendered HTML; with a filter matching only card rows,
  `#filter-summary-cash` is absent.
- The string `Balanço Líquido` never appears inside `#filter-summary-cards`.
- A Pluggy live entry on a cash account is shown in the cash group and one on a
  card account in the card group; neither is dropped from the strip.
- This task's own staged diff adds no line containing `cash_accounts_only` or
  `include_credit_cards`, and adds no `/statements` link to the transactions
  template. CL-33's existing `Scopes.cash_accounts_only` calls in
  `lib/cash_lens/transactions.ex` (the transfer and forecast queries) stay in
  place: the file still holds at least four such calls, and this task's staged
  diff **deletes** none of them. The count is deliberately a floor, not an
  exact number — CL-31 adds further calls to the same file and may land first.

## Expected Results

- [ ] `get_filtered_summary/1` returns `%{cash: ..., cards: ...}`, each with
      `income`, `expenses` and `count`, and both keys always present.
- [ ] The strip shows cash and card figures separately, with no figure adding them.
- [ ] The card group shows `Gastos` and `Créditos` and no `Balanço Líquido`.
- [ ] A group with no rows is omitted rather than rendered as zeros.
- [ ] The caption and `count_transactions/1` are unchanged.
- [ ] Live-preview entries are grouped by their account's `is_credit_card` and
      keep contributing to the strip (and to their group's `count`).
- [ ] This task introduces no cash-account restriction and no
      opt-in/opt-out filter key; CL-33's existing `Scopes.cash_accounts_only`
      calls remain (none deleted by this diff; the file's count is a floor of
      four, since CL-31 may add more to the same file).

## Out of Scope

`/balances` (CL-35), `/months` (CL-31), the dashboard, the JSON API,
`CashLens.Accounts.Scopes` and its existing consumers, `/statements`, the
transactions table body and its filters.
