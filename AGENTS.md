# AGENTS.md — CashLens Project Manifest

This document is the domain and architectural reference for anyone (human or AI agent) working on
CashLens. It describes what the system does, how it's built, where things live, and the
vocabulary the codebase uses for its business logic.

## Project Context & Purpose

CashLens is a **personal finance tracking application** built for a single user (no
multi-tenancy, no login/auth layer today — see `BACKLOG.md` for future SaaS/auth plans). It
solves the problem of consolidating money movement across many disconnected sources — bank CSV/OFX
exports, credit-card PDF/text statements, and live Open Finance bank connections — into one
place where transactions can be categorized, reconciled, and turned into monthly balances and
forward-looking forecasts.

Core jobs the app performs:

- **Ingest** transactions from files (CSV, OFX, PDF, proprietary TXT formats) or from live bank
  connections via the Pluggy Open Finance API.
- **Deduplicate** aggressively and safely, so the same statement can be re-imported or re-synced
  without creating duplicate rows, while still preserving genuinely repeated same-day charges.
- **Categorize** transactions (manually, via keyword rules, or via a suggestion engine based on
  historical categorization of similar descriptions).
- **Reconcile** credit-card statements against the payment transaction that settles them, link
  transfers between the user's own accounts, link reimbursable expenses to their reimbursements,
  and detect/group installment ("parcelado") purchases.
- **Report** monthly balances per account (a chained/rolling balance model) and produce a
  forward-looking cash-flow **forecast** from recurring income/expense items.

The intended user is the app's own owner/developer, managing their personal (Brazilian) bank and
credit-card accounts — hence Portuguese terms appearing throughout the domain model (e.g.
`competencia`, `fatura`, `parcelas`).

## High-level Architecture

CashLens is a **monolithic Phoenix 1.8 + LiveView application** — no separate frontend SPA, no
microservices. Server-rendered LiveViews handle nearly all interactive UI; a small JSON API
exists alongside for programmatic/read access.

```
Browser (LiveView sockets + minimal JS hooks)
        │
        ▼
Phoenix Endpoint (Bandit adapter)
        │
        ├── Router: browser pipeline → LiveViews (primary UI)
        ├── Router: api pipeline     → JSON REST controllers (read-mostly)
        │
        ▼
Context layer (lib/cash_lens/*.ex — Phoenix "contexts")
   Accounts · Transactions · Categories · Accounting · CreditCards ·
   Installments · Forecast · Pluggy · Parsers · Settings
        │
        ▼
Ecto schemas + Repo → PostgreSQL
        │
        ├── Oban (async job queue) — e.g. RecalculateBalanceWorker
        └── Req (HTTP client) — outbound calls to the Pluggy API
```

Key architectural facts:

- **Contexts own business logic**; LiveViews and controllers are kept thin and delegate to
  context modules (`CashLens.Transactions`, `CashLens.Accounting`, etc.) — the standard Phoenix
  "context" pattern.
- **The `Transactions` context is the largest and most central** (~1500+ lines): filtering,
  bulk-ignore rules, auto-categorization, transfer matching/rules, installment linking,
  reimbursement linking, and the dedup fingerprinting scheme all live here or in its
  sibling modules under `lib/cash_lens/transactions/`.
- **Balances are a chained/rolling model** (`CashLens.Accounting`): each month's balance is
  derived from the prior month's, not recomputed from full history each time — noted in
  `BACKLOG.md` as a deliberate but performance-sensitive design choice, with snapshot support
  (`is_snapshot`) as the mitigation.
- **Ingestion is format-agnostic at the boundary**: `CashLens.Parsers.Ingestor` detects/dispatches
  to a format-specific parser (CSV, OFX, PDF, Ourocard TXT) implementing the
  `CashLens.Parsers.Parser` behaviour, normalizes the output, then feeds it through the same
  dedup/auto-categorize/transfer-match pipeline regardless of source.
- **Pluggy sync is a second ingestion path** parallel to file import: `CashLens.Pluggy` manages
  registered "items" (bank connections) and account links; `CashLens.Pluggy.Sync` pulls
  transactions via `CashLens.Pluggy.Client` (a thin `Req`-based wrapper around the Pluggy REST
  API) and feeds them through the same transaction pipeline, tagged with `source: "pluggy"`.
- **Background work** goes through Oban (e.g. balance recalculation after bulk changes) rather
  than blocking request/LiveView processes.
- **No separate frontend build framework** — assets are plain JS/CSS bundled with `esbuild` and
  `tailwind` (v4) via Phoenix's asset pipeline; DaisyUI supplies the component/theme layer on top
  of Tailwind.
- **Settings** (small UI preferences like "last import folder") are persisted to a flat
  `settings.json` file via `CashLens.Settings`, not the database — intentionally lightweight,
  not a general-purpose config store.

## Key Technologies & Stack

| Layer | Technology |
|---|---|
| Language | Elixir ~> 1.15 (repo pinned via `.tool-versions`) |
| Web framework | Phoenix ~> 1.8.3, LiveView ~> 1.1 |
| HTTP server | Bandit |
| Database | PostgreSQL via Ecto + `ecto_sql` / `postgrex` |
| Background jobs | Oban ~> 2.19 |
| Outbound HTTP | Req ~> 0.5 (used for the Pluggy API client) |
| CSV parsing | NimbleCSV |
| Mailer | Swoosh (local adapter in dev) |
| Frontend build | esbuild + Tailwind CSS v4 + DaisyUI (no JS framework/SPA) |
| Icons | Heroicons (vendored via git dependency) |
| i18n | Gettext |
| JSON | Jason |
| Testing | ExUnit, ExCoveralls (coverage), Mox (mocking), LazyHTML (LiveView test helper) |
| Linting/static analysis | Credo (`--strict`), Dialyxir, SonarCloud, DeepSource |
| CI | GitHub Actions (`.github/workflows/`) |
| Containerization | Docker (`Dockerfile`, `docker-compose.yml`) |

Mix aliases worth knowing (`mix.exs`):
- `mix setup` — deps, DB, assets, all in one.
- `mix precommit` / `mix quality_check` — DB setup + compile with warnings-as-errors +
  `deps.unlock --unused` + `mix format --check-formatted` + `credo --strict` + full test suite.
  This is the canonical "is this change safe to commit" command.
- `mix cash_lens.import <path>` — bulk-import statement files from account folders marked with a
  `.account` file (see README.md for the full folder-convention rules).

## Directory Structure

```
lib/cash_lens/                     Business logic ("contexts") — framework-agnostic
  accounts.ex / accounts/          Bank/credit-card accounts (Account schema)
  transactions.ex / transactions/  Core transaction logic:
                                      transaction.ex          — schema + dedup fingerprinting
                                      auto_categorizer.ex      — rule-based categorization
                                      category_suggester.ex    — history-based category suggestions
                                      transfer_matcher.ex      — auto-links transfer pairs
                                      transfer_rule.ex/_applier.ex — user-defined transfer rules
                                      installment_detector.ex  — detects "parcelado" purchases
                                      bulk_ignore_pattern.ex   — regex rules to skip noise txns
                                      rejected_reimbursement_pair.ex — "don't suggest again" list
  categories.ex / categories/      Hierarchical spending categories (Category schema, parent/child)
  accounting.ex / accounting/      Monthly balance calculation (Balance schema)
  credit_cards.ex / credit_cards/  Credit-card statement ("fatura") tracking + payment matching
  installments.ex / installments/  Installment groups spanning multiple months
  forecast.ex / forecast/          Recurring income/expense items → cash-flow forecast
  pluggy.ex / pluggy/              Open Finance integration (items, account links, API client, sync)
  parsers/                         File-format parsers + the Ingestor dispatch/pipeline
    parser.ex        — behaviour all format parsers implement
    csv_parser.ex, ofx_parser.ex, pdf_parser.ex, ourocard_txt_parser.ex
    account_file.ex  — reads `.account` marker files for directory import
    pdf_converter.ex — PDF → text conversion (pluggable, see `:pdf_converter` config)
    ingestor.ex       — main import entry point: parse → dedup → categorize → transfer-match
    directory_importer.ex — bulk folder import used by the `cash_lens.import` mix task
  settings.ex                      Flat-file (settings.json) key/value UI preferences
  workers/                         Oban workers (e.g. recalculate_balance_worker.ex)
  repo.ex, application.ex, mailer.ex — standard Phoenix/OTP boilerplate

lib/cash_lens_web/                 Web layer (Phoenix)
  router.ex                        Route table: browser (LiveView) + /api (JSON) pipelines
  live/                            LiveView modules, one folder per resource:
                                      account_live/, transaction_live/, category_live/,
                                      balance_live/, month_live/, reimbursement_live/,
                                      transfer_live/, credit_card_statement_live/, pluggy_live/,
                                      installment_live/, forecast_live/, automation_live/
                                      (bulk_ignore + transfer_rules), admin_database_live.ex
  controllers/api/                 JSON REST controllers (accounts, categories, transactions,
                                      balances, installment_groups)
  components/                      Shared UI components + app layouts
  formatters.ex                    Shared view-layer formatting helpers (currency, dates, etc.)

lib/mix/tasks/                     Custom mix tasks (import, backfill_statements,
                                      migrate_ourocard_txt, recompute_competencia,
                                      reconcile_pending_statements, migrate_credit_card_transfers)

assets/                            Frontend source: js/app.js, css/app.css, vendor/ (DaisyUI,
                                      Heroicons, topbar), bundled via esbuild + Tailwind
priv/repo/migrations/              Ecto database migrations (schema history / source of truth)
priv/repo/seeds.exs                Seed data
test/                              ExUnit tests, mirrors lib/ structure 1:1
  support/fixtures/                Shared test fixtures/factories
config/                            config.exs (compile-time), dev.exs, prod.exs, runtime.exs
                                      (env-var driven, e.g. DATABASE_URL, SECRET_KEY_BASE), test.exs
BACKLOG.md                         Architectural decisions + prioritized backlog (Portuguese) —
                                      read this for the "why" behind current design and known risks
```

## Domain Concepts

- **Account** — a bank account or credit card the user owns. Has `is_credit_card`, `closing_day`
  and `due_day` (for statement cycles), `accepts_import`, and a `parser_type` selecting which
  file-format parser handles its statements.
- **Transaction** — a single money movement. Carries a `source` (`"file"`, `"pluggy"`, or
  `"manual"`), an optional link to a `Category`, and optional links used for the reconciliation
  features below.
- **Dedup key / fingerprint** — the mechanism preventing duplicate transactions on re-import or
  re-sync. `dedup_key/1` builds a normalized identity string
  (`account_id|date|time|amount_cents|normalized_description`), where time absent/unparseable
  always collapses to a fixed constant so it can't flip between imports. `fingerprint/2` hashes
  that key together with an `occurrence_index` (0-based ordinal among identical rows), so N
  genuinely identical same-day charges are preserved while re-importing the same statement
  produces zero duplicates. See the extensive doc comments in
  `lib/cash_lens/transactions/transaction.ex`.
- **Category** — hierarchical (parent/child via `parent_id`) classification of spending, with a
  `type` of `"fixed"` or `"variable"` and an auto-generated hierarchical `slug`. Used for
  reporting, forecasting, and auto-categorization rules.
- **Competência** — the accounting/reference month a credit-card statement or balance belongs to,
  as distinct from the calendar date a transaction posted (Brazilian accounting term; appears as
  a `competencia` field/date on `CreditCards.Statement` and in balance calculations).
- **Fatura** — Portuguese for "credit-card statement/invoice." Modeled as
  `CashLens.CreditCards.Statement`: one per billing cycle per credit-card account, with a
  `due_date`, `total_a_pagar` (amount due), and a link (`payment_transaction_id`) to the bank
  transaction that actually paid it. Statements can be `absorbed_by` another statement (merge
  case, e.g. a corrected re-import).
- **Balance (chained/rolling)** — one row per account per (year, month) in
  `CashLens.Accounting.Balance`: `initial_balance`, `income`, `expenses`, `transfers_in/out`,
  `balance`, `final_balance`. Each month is computed from the previous month's final balance
  rather than from full transaction history, with `is_snapshot` marking a balance recomputed as a
  performance checkpoint.
- **Installment group ("parcelas")** — `CashLens.Installments.InstallmentGroup` ties together the
  individual monthly transactions of a purchase paid in installments (e.g. "12x"), matched by a
  `description_pattern`. `InstallmentDetector` identifies candidate installment purchases from
  incoming transaction descriptions (typically containing a "PARC xx/yy" marker).
- **Transfer** — a movement of money between two of the user's own accounts, which should net out
  of income/expense totals. `transfer_key` links the two transaction rows that make up a
  transfer pair. `TransferRule` lets the user pre-declare source/destination account +
  description-pattern rules so transfers auto-match and can auto-create the "mirror" transaction
  on the other account (`create_mirror`). `TransferMatcher` performs the runtime matching.
- **Reimbursement** — an expense the user expects to be paid back for.
  `reimbursement_status`/`reimbursement_link_key` on `Transaction` track the link between the
  original expense and the incoming reimbursement payment; `RejectedReimbursementPair` remembers
  pairs the user explicitly said are *not* a match, so they aren't suggested again.
- **Bulk ignore pattern** — a user-defined regex (`CashLens.Transactions.BulkIgnorePattern`)
  matched against transaction descriptions to bulk-exclude recurring noise (e.g. informational
  bank notices) from import.
- **Auto-categorizer vs. category suggester** — two distinct mechanisms:
  `AutoCategorizer` applies deterministic rule-based classification (e.g. transfer rules) at
  ingestion time; `CategorySuggester` is a virtual, non-persisted suggestion
  (`suggested_category` field) computed on the fly from how identically-described transactions
  were categorized historically, shown as a hint in the UI.
- **Pluggy item / account link** — `Pluggy.Item` is one registered Open Finance bank connection
  (`item_id` from the Pluggy API); `Pluggy.AccountLink` maps one Pluggy-reported account within
  that item to a local `Account`, and tracks `pluggy_balance`/`last_synced_at`. `Pluggy.Sync`
  pulls new transactions per linked account through the same ingestion pipeline used for file
  imports, tagged `source: "pluggy"`.
- **Recurring item / forecast** — `CashLens.Forecast.RecurringItem` is a predicted recurring
  income or expense (salary, rent, subscriptions) with a `category`, `day_of_month`, and
  `amount`; `is_salary` flags income items. The Forecast context projects these forward to build
  a cash-flow forecast view.
- **Parser behaviour** — any statement-format parser (`CSVParser`, `OFXParser`, `PDFParser`,
  `OurocardTXTParser`) implements `parse(content, format) :: [transaction_map]`, decoupling the
  `Ingestor` pipeline from format-specific extraction logic. `.account` marker files (bank name +
  account name) determine which parser and account a folder of statement files is routed to.











<!-- MERIDIAN_INSTRUCTIONS_START -->
# Meridian Instructions

> **AI Task Management**: If an AI agent needs to create, update, or read project tasks, it MUST go through the Meridian server first — the server owns the timestamps, so it is the only write path that keeps them consistent. Read the board with `GET http://localhost:3333/api/status?project=<absolute project path>` — this no longer carries `expected_results`. Read one task's `expected_results` with `GET http://localhost:3333/api/projects/tasks/<task id>?project=<absolute project path>`. Create with `POST http://localhost:3333/api/projects/tasks`, update with `PUT http://localhost:3333/api/projects/tasks/<task id>` (both writes take `projectPath` in the JSON body, and both accept `expected_results`). Only when the server is not running — the request fails to connect and `node cli.js start` is not an option — may an agent fall back to hand-editing `.meridian/tasks.jsonl` (and `.meridian/tasks/<task id>.json` for `expected_results`) directly, writing the detail file before the line and applying the timestamp rules below by hand.
> **File Shape**: `.meridian/tasks.jsonl` is one compact JSON object per line, one task per line — NOT an array and NOT an object with a `tasks` key. `expected_results` does not travel on the line: it lives in `.meridian/tasks/<task id>.json` as `{"expected_results": [...]}`, present only when the array is non-empty. A task's line carries `id`, `title`, `status`, `priority`, `justification`, `blockedBy`, `running`, `created_at`, `updated_at`, `moved_at` and `completed_at`. Never delete a task — move it to `nope` instead.
> **Timestamps**: ISO-8601 UTC strings. `created_at` is set once, on creation. `updated_at` is set on every write. `moved_at` is set on every status change. `completed_at` is set when the status enters `done` and set back to `null` when it leaves `done`. The server stamps all four; a hand-edit must reproduce them exactly.
> **Priority (`priority`)**: EXACTLY one of `critical`, `high`, `medium`, `low`. A task without one is read as `medium`.
> **Active Execution (`running`)**: boolean flag (`true`/`false`). Set to `true` when an agent starts actively working on a task, and set to `false` when finished or handed off.
> **Dependencies (`blockedBy`)**: optional array of task IDs that must reach `done` before this task can proceed. A task with a non-empty `blockedBy` whose dependencies aren't all `done` yet should have status `blocked` — that dependency is sufficient justification on its own (e.g. `justification: "Blocked on <task-id>"`). When every task in `blockedBy` reaches `done`, move this task back to `backlog`.
> **Allowed Statuses**: When assigning a status to a task, you MUST use EXACTLY one of the following lowercase strings. They carry no spaces and no slashes. DO NOT invent new statuses or use synonyms like 'pending', 'todo', 'completed', 'in progress' or 'qa/review'.
  - `backlog`: Task is planned but not ready to be worked on yet.
  - `spec_review`: Task needs specification or design review.
  - `ready_todo`: Task is fully specified and ready to be picked up.
  - `in_progress`: Task is currently being worked on by developer.
  - `code_review`: Task code is being reviewed for architecture, security, and test quality.
  - `qa_review`: Task is being verified independently by QA against expected results.
  - `blocked`: Task cannot proceed due to external dependencies.
  - `done`: Task is fully completed.
  - `nope`: Task was cancelled or won't be done.
> **Implementation Rule**: Before starting any implementation work, ask the user if they want to create a task for it in the Meridian system.
<!-- MERIDIAN_INSTRUCTIONS_END -->
