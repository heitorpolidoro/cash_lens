# CL-17 — Unificar Regras de Automação (/admin/automation) combinando regras de exclusão e regras de transferência

## Scope
Merge the two scattered rule screens (`/admin/exclusion_rules`, backed by `CashLensWeb.AutomationLive.BulkIgnore`, and `/admin/transfer_rules`, backed by `CashLensWeb.AutomationLive.TransferRules`) into a single Automation Center LiveView served at `/automation`, with the two legacy paths redirecting to it. The unified screen replaces the fixed side form of both old screens with a modal, presents transfer rules as flow cards (source account to destination account) instead of a table, and adds a live regex tester to the exclusion tab.

**No count or quantity indicator is rendered anywhere on this screen.** There are no metric/summary cards, and the tab labels carry no aggregate numbers in their text — only the tab name and its icon. This is a hard requirement of the design, not an omission.

Covered:
- Unified route and tabbed navigation ("Regras de Transferência" and "Exclusão de Ruído / Regex").
- Transfer rules rendered as flow cards: label, `[source account] ➔ [destination account]`, mirror badge, and chips with the statement patterns that trigger the rule.
- Regex quick tester on the exclusion tab: the typed description is matched against every registered pattern, with an immediate visual verdict.
- Modal create/edit for both rule kinds, replacing the two static side forms.
- Tests consolidated into `test/cash_lens_web/live/automation_live/index_test.exs`.

Not covered:
- Any change to the `transfer_rules` / `bulk_ignore_patterns` tables, their schemas, or migrations.
- Any change to the batch applier (`CashLens.Transactions.reapply_transfer_rules/0`) or to the ingestion pipeline.
- Enabling/disabling a rule: `TransferRule` has no `active` column, and adding one would be a migration, which is out of scope. No active/inactive badge or toggle is rendered.

![Mockup](CL-17-mock.html)

## Approach

### 1. Behavior
- `/automation` mounts a new LiveView that loads transfer rules, bulk-ignore patterns and active accounts at once. Each legacy path redirects to the unified route on the tab that corresponds to it: `/admin/transfer_rules` → `/automation?tab=transfers`, `/admin/exclusion_rules` → `/automation?tab=exclusions`.
- The active tab comes from the `tab` query param (`transfers` — the default — or `exclusions`) and is kept in the socket; switching tabs does not remount.
- The page header button creates a rule of whichever kind the active tab shows; its label follows the tab ("Nova Regra de Transferência" / "Novo Padrão Regex de Ruído").
- The regex tester takes the typed description on every change and reports either the first registered pattern that matches it (the transaction would be ignored) or that no pattern matched (the transaction would be kept). The match verdict shows the **pattern source text** (`BulkIgnorePattern.pattern`), not the human-readable `description`. Patterns that fail to compile are skipped rather than crashing the LiveView.
- A bulk-ignore pattern row renders exactly two fields, because the schema has exactly two: `pattern` (as a monospace chip) and `description`. No provenance, scope or "where it is applied" line is rendered — no such field exists.
- Editing a bulk-ignore pattern is new behavior: the old screen only created and deleted them.

### 2. Files Touched
- `lib/cash_lens_web/router.ex`: replaces the two legacy `live` routes with `live "/automation", AutomationLive.Index, :index` plus redirects for the old paths.
- `lib/cash_lens_web/live/automation_live/index.ex`: new unified LiveView. It is genuinely new code, not a merge of the old `mount/3` and `handle_event/3` callbacks as-is: both old modules define `validate`, `save` and `delete` with different param keys (`"bulk_ignore_pattern"` vs `"transfer_rule"`), so the events must be renamed per rule kind, and both old renders are restructured (table to flow cards; side form to modal).
- `lib/cash_lens_web/live/automation_live/bulk_ignore.ex` and `lib/cash_lens_web/live/automation_live/transfer_rules.ex`: deleted; their behavior (pattern CRUD, transfer-rule CRUD, the `description_patterns_raw` comma-separated parsing and re-serialization on edit) moves into the new LiveView.
- `lib/cash_lens/transactions.ex`: adds `update_bulk_ignore_pattern/2`, which does not exist today and is required by the pattern edit modal. No other context change.
- `lib/cash_lens_web/components/layouts.ex` (the nav lives in `nav_groups/1` there, not in an `app.html.heex` template): the two "Administração" menu entries ("Regras de Exclusão" and "Regras de Transferência") collapse into one entry pointing at `/automation`.
- `test/cash_lens_web/live/automation_live/index_test.exs`: new consolidated test file, replacing `bulk_ignore_test.exs` and `transfer_rules_test.exs` (both deleted).

### 3. Test Criteria
Asserted literals must match the mock copy exactly. `test/cash_lens_web/live/automation_live/index_test.exs` covers:
- `GET /automation` renders the page title "Central de Automações & Regras", both tab labels "Regras de Transferência" and "Exclusão de Ruído / Regex", and the transfers section heading "Regras de Pareamento e Criação de Espelho".
- The rendered page contains no count indicator: the rendered HTML is refuted against `~r/\(\d+\)/` (no parenthesised number anywhere, so no numeric suffix on a tab label), and `Floki.find(html, ~s([data-role="metric-card"]))` returns `[]`.
- `GET /admin/transfer_rules` redirects to `/automation?tab=transfers`, and `GET /admin/exclusion_rules` redirects to `/automation?tab=exclusions`; each assertion matches the full destination including the `tab` param.
- Switching to the exclusions tab renders "Padrões Regex para Ignorar Ruídos de Extrato" and the tester heading "Testador Rápido de Regex", and hides the transfers section.
- A transfer rule with a mirror enabled renders its label, both account names, the "Gera Espelho" badge and each of its description patterns as a chip under "Padrões no extrato:".
- Creating a transfer rule through the modal persists it and it appears in the list; editing one pre-fills the comma-joined patterns and the update persists; deleting removes it from the list and its delete control carries a `data-confirm` guard.
- Creating, editing and deleting a bulk-ignore pattern through the modal all work, and the pattern's delete control carries a `data-confirm` guard; an invalid regex is rejected with the changeset error instead of being saved.
- The regex tester returns the matching-rule verdict ("Corresponde à regra:") followed by the pattern's own source text (not its `description`) for a description covered by a registered pattern, and the keep verdict ("Nenhum padrão de exclusão casou.") for one that is not. The test fixture uses a pattern whose `pattern` and `description` differ, so the verdict cannot pass with the wrong field.
- A bulk-ignore pattern row renders its `pattern` and its `description` and nothing else: the row's text is refuted against "Aplicado" (no provenance line).
- `mix test test/cash_lens_web/live/automation_live/index_test.exs` passes (from the host, `.env` points `DATABASE_HOST` at the Docker-only `db`, so run it as `DATABASE_HOST=localhost DATABASE_PORT=54321 mix test ...`).
- No NEW credo findings are introduced in the files this task touches (the repository already carries pre-existing `credo --strict` findings in untouched files, so a clean `mix quality_check` is not a valid gate), and `mix format --check-formatted` is clean on those files.

## Expected Results
- [ ] Unified automation center reachable at `/automation` (page title "Central de Automações & Regras"), with tabs for transfer rules and regex exclusion rules; `/admin/transfer_rules` redirects to `/automation?tab=transfers` and `/admin/exclusion_rules` redirects to `/automation?tab=exclusions`
- [ ] No count or quantity indicator is rendered anywhere on the screen: the page HTML contains no `[data-role="metric-card"]` element and no parenthesised number (`~r/\(\d+\)/`)
- [ ] Transfer rules are rendered as flow cards showing source account to destination account, the mirror badge and the statement pattern chips
- [ ] The exclusion tab has a live regex tester that reports, for a typed description, either the matching pattern's source text ("Corresponde à regra:" plus the `pattern` field, not the `description`) or "Nenhum padrão de exclusão casou."
- [ ] Each bulk-ignore pattern row renders only the two fields the schema has, `pattern` and `description`, with no provenance/scope line
- [ ] Rules of both kinds are created and edited through a LiveView modal; neither of the old fixed side forms remains
- [ ] On the exclusions tab the header button opens the exclusion form (fields `pattern` and `description`), never the transfer form, and each pattern row's edit action opens that same modal pre-filled with the row's values
- [ ] Editing an existing bulk-ignore pattern persists the change (new behavior, backed by `update_bulk_ignore_pattern/2`); the delete control of a pattern and of a transfer rule alike is guarded by a `data-confirm` confirmation
- [ ] No new credo findings in the files this task touches and `mix format --check-formatted` is clean on those files, and the consolidated `test/cash_lens_web/live/automation_live/index_test.exs` suite passes (run from the host with `DATABASE_HOST=localhost DATABASE_PORT=54321 mix test`)

## Out of Scope
- Database migrations, including any `active` flag for transfer rules.
- Changes to the ingestion pipeline or to the batch transfer-rule applier.
