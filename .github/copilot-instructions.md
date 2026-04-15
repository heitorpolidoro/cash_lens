# Copilot instructions for CashLens

Purpose: give future Copilot sessions the essential commands, architecture overview, and repository-specific conventions to be effective quickly.

---

## Quick commands

- Setup (first time):
  - mix setup
  - (alias runs: deps.get, ecto.setup, assets.setup, assets.build)
- Start dev server:
  - mix phx.server
  - or: iex -S mix phx.server (interactive)
- Assets (dev):
  - mix assets.setup
  - mix assets.build
  - Assets watchers are run by the endpoint (esbuild & tailwind target: `cash_lens`)
- Database:
  - mix ecto.setup (creates + migrates + seeds)
  - mix ecto.migrate
  - mix ecto.reset
- Tests:
  - Full suite: mix test
    - The `test` alias already runs `ecto.create` and `ecto.migrate --quiet` for TEST env.
  - Single test file: mix test test/path/to/file_test.exs
  - Run a single test by line: mix test test/path/to/file_test.exs:42
- Formatting / lint-ish checks:
  - mix format
  - mix compile --warnings-as-errors (used in precommit/CI)
  - Precommit alias: mix precommit (runs compile with warnings as errors, deps.unlock --unused, format, test)
- Production assets:
  - mix assets.deploy

---

## High-level architecture (big picture)

- Framework: Phoenix 1.8 app with LiveView as the primary UI layer (lib/cash_lens_web).
- Web surface: LiveViews, LiveComponents, HEEx templates; core UI helpers under CashLensWeb.CoreComponents and Formatters.
- Persistence: Ecto + Postgrex (CashLens.Repo configured in config/*.exs). DB tasks and migrations live under priv/repo.
- Assets: esbuild + Tailwind via mix tasks; watchers configured for the `cash_lens` asset profile.
- Domain: financial/accounting-focused app. Statement parsers and ingestion helpers live in statements/ and are referenced in TODOs.
- ML/automation: repo TODOs/GEMINI.md mention planned ML-based categorization (ml/*) and OFX parser; treat ML integration as a separate service/integration point.
- Single-user oriented currently (GEMINI.md notes single-user design); multi-tenancy/auth is not implemented by default.

---

## Key repository conventions and patterns

- Mix aliases are relied upon for common flows. Prefer using `mix setup`, `mix ecto.setup`, and `mix precommit` rather than running long command chains.
- Test compilation: `elixirc_paths(:test)` includes `test/support` — support modules are compiled in test env.
- Precommit/CI: the `precommit` alias enforces `compile --warnings-as-errors` and runs `deps.unlock --unused` before formatting and tests; address warnings and unused deps to pass CI locally.
- Assets profile naming: tailwind & esbuild tasks use the `cash_lens` profile (e.g., `esbuild cash_lens`). Use the same profile names when scripting asset tasks.
- LiveView refactor guidance: TransactionLive.Index is a known hotspot (see GEMINI.md/TODO). Break large LiveViews into smaller components where appropriate.
- Seeds: seeding code is at priv/repo/seeds.exs and is invoked by `mix ecto.setup`.

---

## AI / assistant config notes discovered

- GEMINI.md exists and contains repository engineering directives (March 2026):
  - Prefer PostgreSQL; avoid MongoDB for this project.
  - Watch for performance issues in chained-balance/accounting logic and plan for snapshots.
  - Short-term roadmap: refactor TransactionLive.Index, implement OFX parser, integrate ML categorization.
  - Copilot sessions should respect these higher-level decisions when suggesting architecture or storage changes.

- No CLAUDE.md, AGENTS.md, AIDER_CONVENTIONS.md, .cursorrules, .windsurfrules, or .clinerules were detected.

---

## Where to look quickly

- Entry points: lib/cash_lens_web (web), lib/* (domain)
- Mix tasks & aliases: mix.exs
- Dev DB config: config/dev.exs (CashLens.Repo)
- Parsers/ingest: statements/
- Roadmap/comments: TODO*.md and GEMINI.md

---

Would you like assistance configuring any MCP servers (for example Playwright-based E2E for the web app) for this repository?