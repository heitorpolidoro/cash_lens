# 🗺️ Meridian Project Standards — cash_lens

## 🎯 Project Overview

**cash_lens** is a personal finance tracking web application for importing, categorizing, and analyzing bank transactions.

| Layer | Technology |
|---|---|
| Language | Elixir 1.18.4 / OTP 28 |
| Web Framework | Phoenix 1.8.3 + LiveView 1.1.24 |
| HTTP Server | Bandit |
| Database | PostgreSQL 15 (Ecto) |
| Background Jobs | Oban (queues: `default: 10`, `accounting: 5`) |
| CSS | Tailwind CSS v4.1.12 |
| JS Bundler | esbuild |
| Test Coverage | ExCoveralls → SonarCloud |
| Linting | Credo + Dialyxir |

---

## 🛠️ Critical Commands

```bash
# Initial setup (deps + DB + assets)
mix setup

# Run development server
iex -S mix phx.server

# Full quality gate (must pass before any commit or PR)
mix quality_check

# Individual quality steps
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test

# Coverage reports
mix coveralls.html    # local HTML report
mix coveralls.xml     # XML for CI / SonarCloud

# Database lifecycle
mix ecto.reset        # drop → create → migrate → seed

# Asset pipeline
mix assets.build      # dev build (unminified)
mix assets.deploy     # prod build (minified + digest)
```

---

## 🏗️ Structure & Navigation

```
lib/
├── cash_lens/                  # Business logic (contexts + internals)
│   ├── accounting.ex           # Context: balance management
│   ├── accounts.ex             # Context: bank accounts
│   ├── categories.ex           # Context: transaction categories
│   ├── transactions.ex         # Context: transactions (CRUD + queries)
│   ├── accounting/balance.ex   # Schema: Balance
│   ├── accounts/account.ex     # Schema: Account
│   ├── categories/category.ex  # Schema: Category
│   ├── transactions/           # Schemas + helpers: Transaction, AutoCategorizer,
│   │                           #   TransferMatcher, BulkIgnorePattern
│   ├── parsers/                # File parsers: CSV, OFX, PDF + Ingestor
│   └── workers/                # Oban workers (RecalculateBalanceWorker)
│
├── cash_lens_web/              # Web layer
│   ├── live/                   # LiveView modules (one subdir per domain)
│   │   ├── account_live/
│   │   ├── automation_live/
│   │   ├── balance_live/
│   │   ├── category_live/
│   │   ├── reimbursement_live/
│   │   └── transaction_live/   # Richest live view; import modal + components
│   ├── components/             # Shared UI components + layout templates
│   ├── controllers/            # Thin HTTP controllers (errors, static page)
│   ├── formatters.ex           # Date, currency, number display helpers
│   └── router.ex               # Route definitions
│
test/
├── cash_lens/                  # Unit tests (mirrors lib/cash_lens/)
├── cash_lens_web/              # LiveView + controller integration tests
└── support/
    ├── fixtures/               # Factory helpers + file fixtures (CSV, OFX, PDF)
    ├── conn_case.ex            # HTTP test base
    └── data_case.ex            # Ecto test base
```

---

## 📏 Golden Rules

1. **Warnings are errors.** `mix compile --warnings-as-errors` runs in CI and `quality_check`. Fix the warning, don't suppress it.
2. **No unused deps.** `deps.unlock --unused` is part of `quality_check`. Remove deps when you stop using them.
3. **Credo strict in CI.** All Credo checks must pass before merging. `TODO` tags in code cause a non-zero exit (exit_status 2 in `.credo.exs`).
4. **Context boundaries are sacred.** Business logic lives in contexts (`Accounting`, `Accounts`, `Categories`, `Transactions`). LiveViews and controllers call contexts only — never Ecto schemas directly.
5. **Binary IDs everywhere.** All schemas use `binary_id` (UUID) as the primary key. Do not introduce integer PKs.
6. **UTC datetimes.** All datetime fields use `utc_datetime` or `utc_datetime_usec`. No naive datetimes.
7. **Max line length: 120.** Enforced by Credo (low priority but tracked).
8. **Format before committing.** `mix format --check-formatted` blocks CI. Run `mix format` locally.
9. **Parsers are isolated.** CSV, OFX, and PDF parsers in `CashLens.Parsers.*` must not depend on Ecto. They return plain data structures that the Ingestor persists.
10. **Test data via fixtures.** Use the helpers in `test/support/fixtures/` for all test data setup. No raw `Repo.insert!` calls in test bodies.

---

## 🧪 Quality & Workflow

### Quality Gate (`mix quality_check`)

All six steps must pass — failure in any blocks the pipeline:

| Step | What it checks |
|---|---|
| `ecto.create / migrate` | DB schema is up to date |
| `compile --warnings-as-errors` | Zero compiler warnings |
| `deps.unlock --unused` | No orphaned dependencies |
| `format --check-formatted` | Code is formatted |
| `credo --strict` | All Credo rules pass |
| `test` | Full test suite passes |

### Coverage

- Coverage is collected by **ExCoveralls** and reported to **SonarCloud** (`sonar-project.properties`).
- Sources: `lib/`. Tests: `test/**/*_test.exs`.
- Exclusions are declared in `sonar-project.properties` for generated/boilerplate files.
- Do **not** skip coverage checks without an explicit user Directive.

### CI

- Runs on: push to `master` / all PRs.
- Runner: `ubuntu-latest`, PostgreSQL 15 service.
- Elixir 1.18.4 / OTP 28.0.4.
- Artifacts: `cover/excoveralls.xml` → SonarQube scan (project: `heitorpolidoro_cash_lens`, org: `heitorpolidoro`).

### Pre-commit

`mix precommit` (alias for `mix quality_check`) should be run locally before pushing. Consider hooking it via a Git pre-commit hook.

### 🤖 Bot Identity & Agent Simulation (Required)

To maintain a consistent audit trail and simulate that actions (branches, commits, and Pull Requests) are performed by the **Meridian Agent**, you MUST use the automated helper script.

#### Using the meridian-agent Wrapper
The `.meridian/meridian-agent` script acts as a transparent proxy for `git` and `gh` commands, automatically injecting the agent's identity and authentication token.

**Usage Example:**
```bash
# Prefix your git/gh commands with the local meridian-agent
.meridian/meridian-agent git checkout -b feature/agent-task
.meridian/meridian-agent git add lib/
.meridian/meridian-agent git commit -m "feat: simulate agent work"
.meridian/meridian-agent gh pr create --title "..." --body "..."
```

### 🚀 Auto-Merge
To enable automatic merging for Pull Requests that pass all status checks, run the following command (this is a separate action from the agent simulation):
```bash
gh pr merge --auto --squash --delete-branch
```
