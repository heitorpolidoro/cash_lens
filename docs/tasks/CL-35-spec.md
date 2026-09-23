# CL-35 — Split Saldos Contábeis into a cash block and a credit-card block

## Scope

`/balances` (`CashLensWeb.BalanceLive.Index`) renders one table whose `<tfoot>`
holds a single row, `TOTAL CONSOLIDADO (N contas)`, produced by
`calculate_totals/1` (`lib/cash_lens_web/live/balance_live/index.ex:157` and
`:465`). That row sums every listed balance — cash accounts and credit cards
together — so its `Saldo Final` adds money you have to money you owe. Measured
on the dev database for 2026-09: non-card rows sum to `19720.28`, card rows to
`-5237.42`, and the screen prints `14482.86`, a number that describes nothing.
The other five summed columns are mixed the same way: the four card rows of
2026-09 contribute `45.50` to `Receitas` and `45.50` to `Despesas`, which are
statement-payment movements, not household income or spending.

This task replaces the single table with **two stacked, independently totalled
blocks**: non-credit-card accounts first, credit-card accounts second. Each
block has its own rows, its own heading and its own total row, so the grouping
is visual and every total sits physically inside the group it sums.

An earlier revision of this spec kept one table and split only the footer into
two rows. That was rejected: with two footer rows the account rows stay
interleaved and the reader has to inspect each row's `Conta` column to know
which kind it is, and the two footer figures sit under rows they do not
describe. Two blocks remove both problems.

Not covered: `CashLens.Accounting.list_balances/3` keeps returning **all**
balances, cards included. No cash-account restriction and no
`include_credit_cards` option is added to it — every account's individual state
is exactly what this screen should list. `lib/cash_lens/accounting.ex`,
`lib/cash_lens/accounts/scopes.ex`, the JSON API, `/statements`,
`/installments`, `/forecast` and `lib/cash_lens_web/live/month_live/show.ex`
are not touched.

## Approach

### Two blocks, cash first

The page body becomes, in source order:

1. `<div id="balances-cash">` — heading `Contas`, table of non-card rows,
   total row `<tr id="balances-totals-cash">`.
2. `<div id="balances-cards">` — heading `Cartões de Crédito`, table of card
   rows, total row `<tr id="balances-totals-cards">`.

Headings are rendered with ids `balances-cash-title` and `balances-cards-title`
so they can be asserted literally. The heading strings, character for
character, accents included, are `Contas` and `Cartões de Crédito`.

A block renders **only when it has at least one row** (operator decision):
filtering the account `<select>` to a credit card makes the whole `Contas`
block — heading, table and total — disappear, rather than showing
`TOTAL EM CONTAS (0 contas) — R$ 0,00`, which reads like a claim about your
money. When neither block has rows, the page renders a single paragraph
`<p id="balances-empty">` with the text
`Nenhum saldo encontrado para os filtros selecionados.`

The year / month / account filters stay where they are, above both blocks, and
apply to the screen as a whole. They are not duplicated per block.

### Classification

A balance is a card row when `balance.account && balance.account.is_credit_card`
— the predicate the rows already rely on. A balance whose account was deleted
(`account == nil`, rendered `Conta excluída`) is a cash row: there is no
evidence it was a card. The dev database currently has no orphan balance rows,
so this is a defensive rule, not an observed case.

### Both totals cover all six numeric columns

Each total row prints `count` plus the six numeric aggregates
(`initial_balance`, `income`, `expenses`, `transfers_in`, `transfers_out`,
`final_balance`). The grouped layout does not change this answer, it
strengthens it: a total placed directly under a block's own rows invites the
reader to add that block's visible column up and compare, so every column must
be a sum of exactly the rows above it. Summing only `final_balance` per block
while leaving the other five consolidated would reintroduce the original defect
inside a layout that denies it exists.

Label text, verbatim:

- `TOTAL EM CONTAS (N contas)` in `#balances-totals-cash`
- `TOTAL EM CARTÕES (N cartões)` in `#balances-totals-cards`

where `N` is the number of rows in that block. This keeps today's counting
semantics (`{@totals.count} contas` already counts rows, so a single account
filtered across two months already reads `2 contas`). Fixing that wording to
count distinct accounts is a separate, pre-existing concern — see Out of Scope.
The string `TOTAL CONSOLIDADO` disappears from the codebase: there is no
consolidated total any more, by design.

### The card total keeps its stored sign

Card balances are stored negative (`-5237.42` for 2026-09) and the card rows
print them negative. The card total is rendered by the same `format_currency/1`
as every other figure, so it prints `R$ -5.237,42`. Presenting it as a positive
"amount owed" would make the total disagree with the very rows it now sits
directly beneath — a contradiction the old footer at least kept at a distance.
The heading `Cartões de Crédito` and the label `TOTAL EM CARTÕES` carry the
meaning; the sign carries the arithmetic.

### Both blocks keep the same column set

`Conta / Período / Saldo Inicial / Receitas / Despesas / Transf. Entrada /
Transf. Saída / Saldo Final`, in both blocks. Dropping the transfer columns
from the card block was considered and rejected: `do_calculate_monthly_balance/3`
(`lib/cash_lens/accounting.ex:48-52`) computes `transfers_in`/`transfers_out`
from the transaction's category alone, with no reference to the account type,
so a statement payment categorised as a transfer lands on a card balance like
any other. That all 43 card rows in the dev database currently show zero
transfers is a property of today's data, not of the model. Identical columns
also keep the two stacked tables visually aligned, which is the point of the
redesign.

### Rendering: two lists, not two streams

`load_balances/2` currently calls `stream(:balances, balances, reset: true)`.
Two blocks need two collections, and `@streams.balances` is neither splittable
nor re-enumerable in the template. The LiveView therefore partitions the plain
list — where `calculate_totals/1` already reduces it — and assigns
`@cash_balances` / `@card_balances` as ordinary lists rendered with `:for`,
dropping `phx-update="stream"`. Streaming buys nothing here:
`Accounting.list_balances/3` is already capped at `page_size` 20, and the
LiveView must hold the full list anyway to compute the totals. Row ids stay
`balances-<balance.id>`, so the existing row-navigation and adjust-modal tests
keep working unchanged.

`calculate_totals/1` returns `%{cash: totals, cards: totals}`, each value with
the shape `empty_totals/0` produces today. The two tables share one private
function component so the row and column markup is written once.

`grep -rn 'calculate_totals\|@totals' lib/ test/` matches only
`lib/cash_lens_web/live/balance_live/index.ex` (lines 157–166, 461, 465) —
re-verified on this branch. The function is private, the assign is local, and
`Api.BalanceController` computes nothing of the sort, so the shape change is
contained.

### Files touched

- `lib/cash_lens_web/live/balance_live/index.ex` — partition in
  `load_balances/2`; `calculate_totals/1` returns `%{cash:, cards:}`; the single
  table is replaced by the two conditional blocks and the empty paragraph.
- `test/cash_lens_web/live/balance_live_test.exs` — the `"consolidated totals"`
  describe block is rewritten for the two blocks: mixed month, card sign,
  per-block omission under filters, and the no-results message.

### Test criteria

Everything runs on the host against the live `./run` Postgres
(`DATABASE_HOST=localhost DATABASE_PORT=5432`); `./run` stays up and the
compose stack is never started. Figures asserted in the LiveView tests are
derived from the fixture values the test itself inserts; any check against dev
data compares the screen to a SQL aggregate recomputed at the same moment, so
it survives new imports.

**Completeness of the partition.** Correct membership (every row in the right
block, no row in both) does not by itself forbid an implementation that filters
a row into *neither* block. The criteria therefore also pin the row count:
the two blocks together must show
`select least(count(*), 20) from balances where year=2026 and month=9`
(currently `10`). The cap is not cosmetic — `load_balances/2` calls
`Accounting.list_balances(filters)` with no page argument
(`lib/cash_lens_web/live/balance_live/index.ex:458`), and
`list_balances/3` defaults to page 1 and `page_size` 20
(`lib/cash_lens/accounting.ex:230`), with no pagination control on the screen,
so the page shows `min(matching rows, 20)` rows and never more. `least(..., 20)`
therefore stays correct if the operator imports enough statements to push
2026-09 past one page, where a bare `count(*)` would start failing a correct
implementation. The check is expressed against the current tree only: no
criterion refers to a "before" state or to commit 83a2532.

`mix quality_check` is not achievable here (~23 pre-existing findings in
untouched files). The bar is the per-file credo baseline measured before the
change: `mix credo lib/cash_lens_web/live/balance_live/index.ex --format=oneline`
prints no findings today and must still print none afterwards. Credo does not
parse `.heex`, and no `.heex` file is touched.

File-scope criteria are expressed against this task's own staged diff
(`git diff --cached`), never against commit 83a2532: CL-31, CL-32 and CL-34 may
land first. `lib/cash_lens/pluggy/live_preview.ex` and
`lib/cash_lens/transactions/category_suggester.ex` carry unrelated uncommitted
work and must never appear staged.

## Expected Results

See the task's `expected_results`.

## Out of Scope

Restricting any query to cash accounts; the JSON API; the dashboard,
month-closing and forecast aggregates; pagination of the balances table (each
block totals the rows it shows from the current page, as the footer does
today); and changing the `N contas` count from rows to distinct accounts, which
is pre-existing behaviour.

Interactive mockup: `docs/tasks/CL-35-mock.html`
