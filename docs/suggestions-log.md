
## [CL-4] Reformular Dashboard (/) com foco no mês atual e layout simplificado — 2026-09-13
- Verify if `month_label/1` helper is used elsewhere before removing it from view helper to avoid unused helper warnings under Credo/warnings-as-errors.
- Keep the light theme classes compatible with the rest of the application layout.

## [CL-5] Reformular tela de Saldos (/balances) com fechamento contábil, linha de total e ajuste de saldo — 2026-09-13
- When creating the adjustment income transaction ("Rendimento do Mês"), verify if the "Rendimentos" category already exists or should be looked up / created automatically.
- Ensure the pencil click uses `phx-click` with JavaScript `event.stopPropagation()` so that clicking the adjustment icon does not inadvertently trigger the row's `push_navigate`.

## [CL-6] Reformular tela de Fechamento do Mês e Comparação (/months) com navegação de ano/mês, simetria e comparativo limpo — 2026-09-13
- For the month steppers, ensure boundary handling wraps or prevents going below/above available calendar ranges gracefully without crashing.
- In comparison mode, visually distinguish negative deltas for expenses (which represent savings / green) from negative deltas for income (which represent reduction / red).

## [CL-8] Redesenhar Central de Importação Inteligente (/imports) — 2026-09-13
- Store import execution history in a lightweight database table or in an ephemeral ETS cache / JSON log to ensure recent import metrics are preserved between page refreshes.
- Provide clear feedback when a selected folder path is invalid or lacks read permissions on macOS.

## [CL-9] Redesenhar Extrato de Transações (/transactions) — 2026-09-13
- For the `InfiniteScroll` hook, include a debounce mechanism or guard against concurrent redundant requests when the user scrolls rapidly.
- Ensure the transition between Health Bar and Filtered Summary is seamless without layout shifting (CLS).

## [CL-10] Unificar formulário manual, edição e modal de confirmação de exclusão de transações — 2026-09-13
- When typing the amount, handle Portuguese currency conventions (comma as decimal separator) seamlessly so both `12,50` and `12.50` parse cleanly into Decimal cents.
- Make sure keyboard shortcut ESC works naturally to dismiss both the form modal and the confirmation modal.

## [CL-11] Redesenhar tela de Parcelamentos (/installments) com suporte a Financiamentos e Consórcios — 2026-09-13
- Set the default value for `commitment_type` in the database migration to `"credit_card"` to ensure existing installment groups are seamlessly backfilled without data migration scripts.
- For consórcios, allow updating the contemplation status (`is_contemplated` / contemplation date) directly from the list card with a single toggle or action button.

## [CL-12] Redesenhar Central de Reembolsos (/reimbursements) com abas de ciclo de vida e conciliação mágica — 2026-09-13
- For partial reimbursements (deposit amount smaller than original expense), provide an inline option to either leave the remainder as pending reimbursement or mark as finalized with user absorption.
- Ensure the floating batch action bar appears only when at least one item is checked, with a clear dismiss/uncheck button.

## [CL-13] Redesenhar Central de Transferências (/transfers) com conciliação inteligente e regras de pareamento — 2026-09-14
- When creating a mirror transaction, ensure the default description includes a clear tag like "[Espelho Transferência]" to ease auditing.
- In the manual link modal, sort candidate opposite transactions by absolute date difference so the closest dates appear first.

## [CL-14] Redesenhar Central de Faturas de Cartão (/statements) com ciclo de vida e conciliação de pagamento — 2026-09-14
- When a payment transaction is linked to a statement, visually flag whether the amount paid was partial or full to aid reconciliation.
- Keep the statement inspection drawer fast by loading transactions lazily only when a specific statement is clicked.

## [CL-15] Redesenhar tela de Contas (/accounts) com visual de cartões bancários e modal de configuração — 2026-09-14
- Provide a clear confirmation dialog or notification before archiving a bank account that has transactions registered in the current month.
- Ensure that the color palette selector includes a custom hex input option alongside popular institutional presets.

## [CL-16] Redesenhar tela de Categorias (/categories) com árvore hierárquica e gestão visual de tipo — 2026-09-14
- When typing in the search bar, automatically expand collapsed parent groups that contain matching subcategories or keywords.
- Include a safety check when attempting to delete a category that still has linked transactions, prompting the user or preventing orphaned transactions.

## [CL-17] Unificar Regras de Automação (/admin/automation) combinando regras de exclusão e regras de transferência — 2026-09-14
- Ensure input validation runs `Regex.compile/1` to give instant inline feedback for invalid regex syntax before saving a rule.
- Keep redirects for `/admin/exclusion_rules` and `/admin/transfer_rules` pointing to `/automation?tab=exclusions` and `/automation?tab=transfers` to prevent broken links.

## [CL-18] Redesenhar Previsão de Caixa (/forecast) com régua de liquidez e itens recorrentes — 2026-09-14
- If no item is currently marked as salary, display a polite prompt on the "Saldo Pré-Salário" KPI card inviting the user to pick their main income recurrence.
- In the liquidity ruler, format dates with day of the week (e.g. "Seg, 15 Set") to make weekend vs banking day impacts immediately apparent.

## [CL-19] Modernizar Layout Global e Menu Lateral com navegação consolidada e tema claro — 2026-09-14
- When clicking a navigation item on mobile screen sizes, ensure the drawer automatically closes via standard LiveView `JS.dispatch` or checkbox uncheck.
- Provide accessible tooltips when the sidebar is in compact collapsed mode so users know which screen each icon represents.

## [CL-13] Redesenhar Central de Transferências (/transfers) com conciliação inteligente e regras de pareamento — 2026-09-15
- Mock line 44 subtitle and spec §Scope line 4 still frame the screen around "double taxation / accounting neutrality"; the cards are gone, but this is the last place that framing survives if the operator wants it dropped from UI copy too.
- `Transactions.create_mirror_transaction/2` referenced at spec line 29 does not exist yet, and §Files Touched line 36 only promises listing helpers — the implementer must author it.

## [CL-14] Redesenhar Central de Faturas de Cartão (/statements) com ciclo de vida e conciliação de pagamento — 2026-09-15
- Spec places the manual-link picker "in the detail view" while the mock puts it on the statement row via a modal, and puts the reconcile block in a page-level banner. Both satisfy the expected results and no test asserts placement, but naming one as authoritative would remove an implementer decision.
- Approach §Reconciliation says the suggestion is "currently only called for statements whose internal status is `:open`" — `statement_status/2` already returns `:open` whenever `payment_transaction_id` is nil, so lifecycle-closed statements are already in that branch. The instruction still lands correctly; the framing just describes a gap that is not there.
- (round 3) The mock's page-header link uses a gear/settings icon; a rules/list icon would read more like "navigate to rules" than "open settings". Cosmetic, not covered by any expected result.

## [CL-15] Redesenhar tela de Contas (/accounts) com visual de cartões bancários — 2026-09-15
- Spec line 16 still describes card parser metadata as "(OFX, PDF, CSV, Ourocard TXT)", but `ourocard_txt` is not one of the eight selectable options. Line 21 is authoritative, so it does not block; the stale parenthetical is worth correcting so nobody adds a ninth option.
- The `ourocard_txt` gap itself (valid parser, unselectable in the form, untranslated) is a real pre-existing defect — worth its own task.
- Spec line 20 promises institutional color presets (Nubank, Itaú, BB…), but the mock shows only a bare `<input type="color">` with no swatches. Add the swatches to the mock or relax the spec wording.
- Carried from round 1: a confirmation step before archiving an account with transactions in the current month.

## [CL-16] Redesenhar tela de Categorias (/categories) com árvore hierárquica e gestão de palavras-chave — 2026-09-15
- No expected_results entry or test criterion covers the parent-with-children delete warning beyond the modal body; consider asserting the disabled state explicitly in a second case.
- Mock badges `Reembolsável por Padrão` and `Marca Reembolso` were unmentioned in the spec until round 2; keep them named so they are not dropped.
- Test Criteria asserts the `disabled` attribute on the confirm button, while the mock also swaps to a `bg-slate-300 cursor-not-allowed` class. The class swap is cosmetic; the real `disabled` attribute is the contract.

## [CL-17] Unificar Regras de Automação (/admin/automation) combinando regras de exclusão e regras de transferência — 2026-09-15
- Mock `<head><title>` still reads "CashLens — Central de Regras de Automação" while the `<h1>` is "Central de Automações & Regras"; nothing asserts the `<title>`, but it is stale copy.
- Each bulk-ignore row's `<div class="space-y-1">` wrapper now has a single child after the provenance span was removed; it can be collapsed.
- The `~r/\(\d+\)/` refutation runs against the whole page HTML — fixture account names and rule labels should avoid parenthesised digits so it cannot fail for an unrelated reason.

## [CL-18] Redesenhar Previsão de Caixa (/forecast) com régua de liquidez e itens recorrentes — 2026-09-15
- The ruler's "Condomínio & Água" row and the list's "Condomínio Edifício Paulista" item are the same -850,00 entry under two names in the mock; align the copy.
- The mock's linear 12-month derivation is illustrative and the spec could say so, since the real `project(365)` will not be flat.
- `openEditModal`'s now-unused `_mode` parameter could be dropped.

## [project-wide] Pre-existing `mix credo --strict` debt blocks the "quality_check passes" criterion — 2026-09-15
- `mix quality_check` exits non-zero at `credo --strict` (2 warnings, 19 refactoring, 2 readability, 7 design) in files unrelated to the current redesign tasks: `lib/cash_lens/transactions.ex`, `lib/cash_lens_web/live/reimbursement_live/index.ex`, `test/cash_lens/accounting_test.exs`.
- Every CL-4..CL-19 task carries "Suite de testes passa com mix quality_check" as an acceptance criterion, which no single task can satisfy without editing unrelated code and polluting its commit.
- Worth its own cleanup task, after which the criterion becomes meaningful again.

## [CL-5] Reformular tela de Saldos (/balances) com fechamento contábil, linha de total e ajuste de saldo — 2026-09-15
- SECURITY-adjacent: `to_integer/1` at `balance_live/index.ex:506` uses `String.to_integer/1` on client-controlled `phx-value` data — a crafted payload crashes the LiveView; `Integer.parse/1` into the existing "Saldo não encontrado" branch closes it.
- DRY: `account_live/index.ex:277-292` duplicates the rendimento-creation rule; it should delegate to `BalanceAdjuster` (its version dates the transaction `Date.utc_today()`, so it is behaviour-affecting).
- The `tfoot` total is capped at `list_balances/3`'s default `page_size: 20` with no pagination UI, so "TOTAL CONSOLIDADO" can silently be a partial sum.
- A negative diff under "Rendimento do Mês" books a negative-amount transaction in the income category (arithmetically correct, semantically odd).
- `format_transfer(nil)` guards a `nil` that `calculate_totals/1` does not — the column is `null: false`, so drop the dead clause.
- Spec drift: `docs/tasks/CL-5-spec.md` "Files Touched" still names `accounting.ex`.

## [CL-6] Reformular tela de Fechamento do Mês e Comparação (/months) — 2026-09-15
- PRE-EXISTING DEFECT worth its own task: `lib/cash_lens/transactions.ex:503-511` — the uncategorized leg of `get_month_category_breakdown/2` does not apply `exclude_transactions_with_children/1` as the categorized leg does, so a re-parented *uncategorized* card bill would be counted alongside its children.
- `total_of/1` in `month_live/show.ex:250` is a generic name for "sum the `:total` field of breakdown rows"; `breakdown_total/1` would read better.
- Crafted `phx-value-scope`/`dir`/`year` params crash the LiveView (MatchError in `move/3` when `comparison` is nil, CaseClauseError on unknown scope, `String.to_integer` on non-numeric input). The chronological guard itself is sound and cannot be bypassed; this is robustness, not an authorization hole.
- `positive?/1` (`month_panel.ex:572`) treats a net of exactly zero as a green "Superávit".

## [CL-11] Redesenhar tela de Parcelamentos (/installments) com suporte a Financiamentos e Consórcios — 2026-09-15
- The consolidated debt card is labelled "Capital total restante a pagar / amortizar", but for a financing `remaining_debt/2` is the remaining payment stream (principal + interest), not capital — `installment_live/index.html.heex:73`.
- `Installments.list_group_transactions(group.id)` is called inside the template for each expanded row (DB query during render), `index.html.heex:389`; `decorate/1` calls `get_group_with_progress/1` once per group (N+1). Both pre-existing.
- New numeric fields (`interest_rate`, `credit_letter_amount`) have no range validation; `contemplated_at` can be set while `is_contemplated` is false.
- `assert html =~ "detectada(s)"` in the admin test passes even for a zero-count scan — assert the count instead.
- `current_month/0` now exists but `upcoming_installments/1` and `first_incomplete_month/0` still compute it inline.
- The new `commitment_type` index is unused (type filtering happens in memory).

## [CL-14] Redesenhar Central de Faturas de Cartão (/statements) — 2026-09-15
- `credit_card_statement_live/index.ex:78` — `@unpaid` is `[:open, :closed]`, so the one-click reconcile block also renders for open cycles, where `total_a_pagar` is nil and the rank degenerates to nearest-date. Carried over from the old code; consider restricting the block to `:closed` in the detail view too.
- `due_label(days) when days < 0` is unreachable, since `next_due/1` filters to dates on or after today.
- Template repeats `@suggestions[group.current.statement.id]` five times and duplicates the reconcile markup between overview and detail — extract a function component.
- `[:open, :closed]` is hardcoded in the template while `@unpaid` exists in code.
- No context-level tests for `lifecycle_status/1`, `group_by_card/1`, `hub_metrics/2`, `payment_candidates/1`; covered only via the LiveView.
- `group_by_card/1` can elect an absorbed statement as the card's `:current` cycle.

## [CL-12] Redesenhar Central de Reembolsos (/reimbursements) — 2026-09-15
- `reimbursement_live/index.ex:987` — `confirm_all` is `Enum.each` over suggestions, atomic per pair but not per batch, and discards the return value. Identical to HEAD; the fix belongs in the context. Overlapping suggested pairs (two expenses + two credits at the same amount) can relink a leg and orphan an earlier link key.
- Partial links mark the expense `"paid"` with no residual record — visible in the UI but not queryable.
- `index.ex:1416` `filter_credits/2` compares the raw term against `Decimal.to_string/1`, so `84,20` matches nothing in the manual link modal, unlike the statement modal.
- `scan_statement/1` routes through `list_transactions/3`, which runs `CategorySuggester.annotate/1` (full scan) on every debounced keystroke, for data the modal never shows.
- `Transactions.list_linked_reimbursement_pairs/0` is now dead public API; `save_reimbursement_details` should pattern-match `tx_id` in the clause head.
- **PRE-EXISTING FINANCIAL-ACCURACY DEFECT, worth its own task.** Confirmed by QA against real data: linking a partial reimbursement marks the expense fully `paid` with no residual record. Example observed: expense -1.000,00 linked to a +400,00 credit leaves both rows `paid` under one link key, and the uncovered R$ 600,00 disappears from every KPI. Lives in the pre-existing `link_reimbursement_group/3`, so outside CL-12's scope, but it silently understates money still owed to the user.

## [CL-19] Modernizar Layout Global e Menu Lateral — 2026-09-15
- `lib/cash_lens_web/live/hooks/active_path.ex` defines `CashLensWeb.ActivePath`, not `CashLensWeb.Live.Hooks.ActivePath` — module name doesn't mirror the file path.
- The collapse toggle's `title`/`aria-label` stays "Recolher menu" when already collapsed, and there is no `aria-expanded`.
- `applyState()` runs on `DOMContentLoaded`, so compact-mode users see a brief flash of the expanded sidebar on cold load.
- The inline `<script>`/`<style>` (inherited from the old layout) would be better in `assets/js/app.js` / `assets/css/app.css`, as the spec suggested.
- `nav_active?/2` is evaluated twice per item (anchor class and icon class).
- (round 2) The toggle regression test asserts markup only and would still pass against the double-binding bug; add a structural assertion on the emitted script (`window.sidebarToggleBound`, `closest("#sidebar-toggle")`) plus a `refute` on `dataset.bound`. The behaviour is inline JS that ExUnit cannot execute and the project has no JS unit-test runner.
- Collapsed state is applied on `DOMContentLoaded`, so a previously-collapsed sidebar renders expanded then animates closed on every full page load; fix by setting the class on `documentElement` from a blocking head script.
- `#app-drawer`'s class list is static in the template, so a future patch of that attribute would strip the runtime `sidebar-collapsed` class; hanging state on `<html>` is structurally immune.

## [CL-9] Redesenhar Extrato de Transações (/transactions) — 2026-09-15
- `CategorySuggester.history_by_normalized_description/0` (`category_suggester.ex:66`) reads every categorized transaction into memory on every page; pre-existing, but infinite scroll now runs it per scroll page.
- `calculate_summary/1` (`transaction_live/index.ex:1284`) recomputes `statement_health/0` even when `filters_active?` hides the bar — four aggregates per search keystroke.
- `#filter-summary-card` pairs `@filtered_count` (includes transfers) with `@summary` (excludes them), so the row count and the totals disagree on transfer-containing slices.
- Pre-existing: `String.to_existing_atom(filters["sort_order"] || "desc")` (`transactions.ex:158`) raises on a crafted value, since `sort_order` is an accepted filter key.

## [CL-10] Unificar formulário manual, edição e modal de confirmação de exclusão — 2026-09-15
- **MONEY-CORRECTNESS RISK:** `transactions/amount_input.ex:127` — `"1,234.56"` (US grouping) silently parses to `1.23456`, and `"1.23,45"` to `123.45`. Decide by the last separator or reject mixed separators. The moduledoc claim that a typo "can never persist a wrong amount" is overstated for that input.
- Pin the ambiguous cases (`"1,234.56"`, `"1.23,45"`, `",50"`) in `amount_input_test.exs`.
- The deleted `form_test.exs` covered "handles error on save"; no new test submits a repo-invalid changeset, so both `{:error, changeset}` branches of `FormComponent.persist/3` are now uncovered.
- `form_component.ex:33` and `:47` duplicate the same three-line validate-changeset block.
- The manual `time` field is no longer editable (the old full-page form had it). In spec, but worth a product confirmation.
- (round 2, parser fix) Values with more than two decimals (`1.2345`) persist as typed into an unconstrained `field :amount, :decimal`, while `to_input_value/1` rounds to 2 — consider rounding at parse time or validating scale.
- The rejection error for `1,234.56` could name the accepted formats.
- Pre-existing: `.5` and `5.` are rejected by the amount parser.

## [CL-21] Criar contexto CashLens.Imports com rastreio de arquivos e histórico de execuções — 2026-09-18
- Reword the spec's "No other line of `ingestor.ex` changes" to "no instrumentation is added anywhere else in `ingestor.ex`" — `process_imported_content/5`'s signature and its call at line 93 do change to thread the raw bytes.
- Follow-up (not this task): collapse a duplicate absolute + relative `imported_files` pair once the monitored root is configured. The no-root case deliberately keys rows absolutely, so a legacy duplicate can exist and is resolved read-side with relative-first precedence.

## [CL-13] Redesenhar Central de Transferências (/transfers) — 2026-09-18
- `transactions.ex:1300` — the tie-break comment/doc say "most recent pair" but the sort key is ascending epoch-days, i.e. oldest first. Documentation drift, untested either way.
- `transactions.ex:1424` — `insert_mirror/2` inserts the mirror and then updates the origin with `{:ok, _} = ...` outside a transaction; a failure leaves a committed mirror holding a lone `transfer_key`.
- `transactions.ex:1628` — `link_transfer_pair/2` could add `where: is_nil(t.transfer_key)` to close the cross-tab race outright.
- Sign filter for link candidates runs in Elixir over a full 30-day window; could be pushed into SQL.
- Suggestion tests pin 2 days (in) / 4 days (out) but not the inclusive boundary at exactly 3 days.
- The pending tab label uses `@pending_count`, which counts suggestion legs shown above the tabs rather than the rows in that tab's table.

## [CL-15] Redesenhar tela de Contas (/accounts) — 2026-09-18
- Parser option labels are hardcoded in `account_live/form_component.ex:19-28` while `index.ex` renders the same strings via `Formatters.translate_parser_type/1` — derive them to prevent drift.
- `close_account_modal` in `index.ex` always patches to `/accounts`, so cancel drops `return_to`; arriving from `import_modal_component.ex:311` the old form's Cancel returned to `/transactions`. Save still honours `return_to`.
- The consolidated total uses latest calculated `final_balance` with fallback to `account.balance`, while the dashboard additionally prefers a stored `pluggy_balance` and adds live entries. Pre-existing per-card difference; consider aligning or documenting it.
- The total's test only exercises the `account.balance` fallback; a case with a rebuilt balance would pin the calculated-balance path.
- `account.color` is interpolated into `style="background-color: …"` (`index.ex:89`, `:172`) with no format validation on the changeset.
- `FormComponent.update/2` rebuilds `:form` on every parent render; theoretical input loss if the parent re-renders while the modal is open.

## [CL-21] Criar contexto CashLens.Imports com rastreio de arquivos e histórico — 2026-09-19
- **CONFIRMED BY QA, worth its own task:** `path`/`file_path` are `varchar(255)`. QA built a 397-character absolute path, imported a valid statement there with no monitored root configured, and observed: Postgres rejects the insert with `22001 string_data_right_truncation`, the error is swallowed by the `rescue` in `record_import/5`, and BOTH rows are lost (`imported_files: []`, `import_runs: []`) while the 3 transactions commit and the caller still receives `{:ok, ...}`. No financial data is lost and the user cannot notice — the only trace is one `[error] INGESTOR: could not record import run` log line. The lasting effect is that the file becomes invisible to the tracking feature and a later `scan/1` calls it `:new` forever. Reachable only through ad-hoc single-file imports; the Drive folder goes through `DirectoryImporter.run/2`, which now always passes its root and produces short relative keys. Fix: migration widening both columns to `:text`.
- `touch_imported_file/4` drops `{:error, changeset}` with no log, unlike `log_record_failure/2` beside it.
- `normalize_root/1` trims only to test blankness and returns the untrimmed binary.
- `scan/1` is not silent — it inherits `maybe_warn_skipped_dir/2`'s warnings from the reused traversal, which the later `/imports` LiveView will emit on every load.
- Symlinked roots are not resolved by `Path.expand/1` (not reachable in production today).
- Extracting a `status_for(summary)` would let the `"warning"` branch be unit-tested directly; end-to-end it needs `prepare_transaction_entry/5` to raise.
- (CL-16 round 4) `Forecast.sync_all/0` only materialises an item once history reaches `@min_occurrences` (`forecast.ex:53-59`), so a newly-marked Fixo category enters the forecast only after enough history and a sync; the hint's present tense is a slight simplification.
- (CL-16 round 4) The tree-side Fixo hint lives only in a `title` tooltip, invisible to touch and keyboard-only users; the modal caption covers discoverability, but a visible caption or `aria-describedby` would be better in a later pass.

## CL-17 — spec review round 3 (2026-09-20)

- **Dead action buttons in mocks are a recurring defect class.** The operator
  found the exclusion rows' `Editar` did nothing; the spec reviewer then found
  the transfer cards' `Excluir` had the same problem one tab over. Both were
  fixed in `CL-17-mock.html`. Worth a habit: before a mock goes to the operator,
  every rendered control should either be wired or visibly inert. A mock that
  presents a live-looking button that does nothing costs a full review round.

## CL-18 — spec review round 3 (2026-09-20)

- **Mock lacks a `:boleto` card row.** The spec says only `:estimado` card
  occurrences carry the "dos quais R$ X são parcelas" disclosure, because a real
  imported boleto's amount is the statement's own total and never passes through
  `estimate_for_month/2`. The mock demonstrates the disclosure present but never
  the case where it is correctly absent, so a reader cannot see the distinction.
  Worth a row when the screen is built.
- **"Visible scrollbar" is not a mechanically verifiable assertion on macOS**
  (overlay scrollbars). Where a test needs to pin scrollability, assert the
  absence of a `scrollbar-hide` utility on the strip instead of the presence of
  a scrollbar.
- **Installments are disclosed inside the card bill, never promoted to their own
  ruler rows.** Doing the latter without reducing the bill estimate by the same
  amount double-counts the money and corrupts every subsequent "Saldo após",
  since `with_running_balance/2` sums occurrences in order. If a future task
  wants per-installment rows, the bill estimate must shrink in the same change,
  with an explicit non-duplication test.

## CL-22 — Criar CashLens.Parsers.FormatDetector — spec review (2026-09-20)

- **C3's gloss on `CSVParser.normalize_header/1` omits its final `[^a-z]` strip step.**
  Worth completing the parenthetical when the module is written, so the predicate
  in the spec and the real normalisation cannot drift.
- **Some Bradesco fixture texts carry neither P3 marker and land on `parser_type: nil`.**
  That is correct behaviour, not a bug — the detector declines rather than guesses.
  Note it in the module `@moduledoc` so a future reader does not "fix" it.
- **The `.pdf` fixture in `test/support/fixtures/files/` is not a real PDF** — 35 bytes
  of plain text with no `%PDF-` magic, a stub for the mocked converter. It is valid
  input for the text path but can never back magic-byte detection. If a real PDF
  fixture is ever needed, it has to be added.

## CL-23 — Criar rota /imports — spec review (2026-09-20)

- **`priv/settings.json` is polluted by an existing test.**
  `batch_import_modal_component_test.exs:143` persists a `batchclose_<n>` tmp path
  through `batch_import_modal_component.ex:58` and never restores it, so a full
  `mix test` leaves the developer's monitored folder pointing at a deleted temp
  directory. The file is gitignored, so nothing flags it. Worth its own task:
  give that component test the same capture/`on_exit` restore CL-23 specifies.
- CL-23 Decision 4's rationale was wrong and was corrected in review:
  `DirectoryImporter` always passes `import_root: root_path`, so batch imports key
  rows relative to the typed path, not the setting.
- `layout_navigation_test.exs` will now mount `/imports` and scan the developer's
  real monitored root — it is not the unset-root case the spec assumed. Worth
  pinning that test to a temp root when the screen is built.
- `hero-arrow-down-tray` is not used anywhere in `lib/` yet; verify it renders
  before relying on it.

## CL-24 — Pre-write Inspection em /imports — spec review (2026-09-20)

- **Mock/spec copy drift** on the empty-state text and on the drawer chrome
  (`<aside>` slide-over in the mock vs the bound `<.modal>` component in the spec).
  Reconcile when the screen is built so the implementer does not have to guess
  which one is authoritative.
- **A note for future dispatches:** review agents that try to run `mix test` fail
  against `localhost:5432`. This project's Postgres is on port **54321**
  (`DATABASE_HOST=localhost DATABASE_PORT=54321 mix test`), because `.env` sets
  `DATABASE_HOST=db`, which only resolves inside Docker. Worth stating in every
  dispatch that may run tests.

## CL-25 — Dropzone universal em /imports — spec review (2026-09-20)

- **`:too_many_files` is not named among the `@uploads.drop.errors` sources**, and with
  `auto_upload: true` a `cancel_upload` does not clear it. Worth handling explicitly
  when the screen is built, or the operator hits a stuck error state.
- **The 65-char path budget interacts with the known `varchar(255)` bug.** The
  `"<content_hash>/"` prefix is a fixed 65 characters, so a dropped filename longer
  than ~190 characters is silently truncated by `imported_files.path`
  (`add :path, :string`). This is the same silent-loss defect already recorded for
  CL-21; the dropzone makes it reachable through a second path.
- **Mock copy diverges** from the spec's no-selection hint
  (`Escolha a conta desta importação.`). Reconcile when building.
- **An OFX credit-card body dropped as `.csv` gets no `credit_card_statements` row**,
  because `statement_meta/2` switches on extension rather than on detected format.
  Detection fixes the parser choice but not the statement-metadata branch.

## CL-26 — Histórico de importações em /imports — spec review (2026-09-20)

- **`ran_at` is `null: false` and required**, so the `ran_at desc, inserted_at desc`
  ordering has no nil case to handle. Noted so nobody adds defensive code for it.
- **Test 7's fallback does not literally satisfy expected result 8.** Driving the
  panel via `import_file/3` plus a `"rescan"` is not "an import confirmed through
  the screen". If CL-24's confirm handler is absent when CL-26 is built, flag that
  expected result rather than ticking it against the weaker path.
- **The `warning` secondary line `[data-role="run-failed"]` has no expected result
  or test criterion.** Either give it one or drop it, so it does not ship untested.

## CL-27 — Remover modais legados de importação — spec review (2026-09-20)

Three capabilities are lost when the legacy import modals are deleted. All three are
named in the CL-27 spec rather than deleted silently, and all three are the operator's
call at the gate:

1. **Automatic installment grouping after a single-file import.**
   `import_modal_component.ex:129` calls `Installments.scan_and_apply_all/0` after its
   uploads, and `directory_importer.ex:98` does the same for folder imports. The
   `/imports` confirm path calls `Ingestor.import_file/3` directly and does not run it,
   so an imported file leaves installments ungrouped until the Admin → Database
   re-scan or `mix cash_lens.import`. Follow-up: run it after a confirmed import on
   `/imports`. Deliberately NOT done in CL-27, which is a removal task.
2. **One-shot folder-wide import of every account.** Still available via
   `mix cash_lens.import <path>`, but no longer from the UI.
3. **Bulk multi-file upload in one action.** The legacy modal declared
   `max_entries: 100`; CL-25's dropzone sets `max_entries: 1` by design (one detection,
   one inspection, one confirmation per file). The largest of the three in daily effort.
   Raising it belongs to CL-25's design, not to CL-27.

Also: the `confirm_create_accounts` account-creation path leaves the UI with the modals;
it remains covered by `mix cash_lens.import` with `create_missing: true`.

## CL-28 — Remove the Gemini CLI leftovers — spec review (2026-09-20)

Two of this task's original board premises were false, both disproved with evidence,
and the spec now says the opposite:

1. **`nodejs npm` must STAY in the image.** The board assumed assets use only the
   esbuild/tailwind Elixir wrappers. They do not: `assets/js/app.js` imports
   `chart.js/auto`, `dompurify` and `flatpickr` from `assets/node_modules`, esbuild
   runs with `cd: assets` and no `--external:` for them, and no `npm install` exists
   anywhere in the repo. Removing node/npm would have broken the asset build. The
   Dockerfile should carry a comment saying why they are there, so this is not
   re-attempted.
2. **`cash_lens_gemini_data` is empty** — no `oauth_creds.json`, so there is no live
   Google OAuth credential to revoke. The volume removal is ordinary disk cleanup,
   not credential disposal. `workspace_gemini_data` does not exist at all.

Remaining notes:
- `rm -rf assets/node_modules` inside the container deletes the HOST directory through
  the bind mount. The rollback text calling this "no persistent state" is wrong.
- The image-size criterion cites two baseline numbers (disk usage and content size)
  without saying which is compared; name one command.

## CL-18 — Previsão de Caixa — spec review round 4 (2026-09-20)

- **The disabled create action's explanation mechanism is unspecified.** The spec says
  the disabled state "carries the explanation"; the mock implements it as a `title`
  tooltip. Name the mechanism so it is not left to the implementer — and note a
  `title` tooltip is invisible on touch and to some screen readers.
- **The sync-survival expected result would be easier for QA to verify** if it named
  the fixture inline (a fixed category whose history suggests values different from
  the ones typed), rather than relying on the test-criteria section.

## CL-23 — rota /imports — code review + QA (2026-09-20)

- **`Reescanear` discards an unsaved typed path.** `assign_scan/2`
  (`lib/cash_lens_web/live/import_live/index.ex:198`) unconditionally does
  `assign(:path_input, root)`, so a path the operator typed but has not saved is
  replaced by the saved root when they press rescan. Reproduced by QA in the live
  view. Judged non-blocking by both code review and QA — nothing is persisted or
  corrupted and the field resets to a truthful value — but it is a real UX wart with
  a two-line fix: preserve `:path_input` when it differs from the saved root.
- `test/cash_lens_web/components/layouts_test.exs:59` asserts a hardcoded nav-entry
  count (`== 16`, bumped from 15 by this task). Asserting the actual path list would
  fail with a readable diff instead of `16 != 15`, and would stop breaking on every
  nav change.
- `Imports.put_import_root/1` returns a bare `:error`; `{:error, :blank}` is more
  idiomatic for a context function.
- `validate_path` and the `@using_default?` hint copy are not directly asserted in
  the new suite.

## CL-24 — Pre-write Inspection — code review + QA (2026-09-20)

Two shipped tests pass vacuously. The BEHAVIOUR is correct in both cases —
QA verified each independently against real data — but the tests would not
catch a regression, which is the point of having them:

- **The LiveView no-write test's `credit_card_statements` leg is vacuous.** Its
  fixture is not a credit-card account, so the count is 0→0 and the assertion
  would pass even if the dry run started writing statements. QA proved the
  guarantee separately with a real `is_credit_card: true` account (0 before, 0
  with the drawer open, 1 only after confirming) and confirmed
  `maybe_create_statement/4` sits structurally inside the non-dry-run arm. Give
  the test a credit-card variant so the four-table assertion means something.
- **The truncation test cannot distinguish the two definitions of N.** The footer
  `mostrando 200 de N linhas` must use the full preview length (new + duplicate).
  QA verified this with a mixed 100-new/150-duplicate file (N = 250, not 100),
  but the shipped test would pass under either definition.
- `import_live_test.exs:268` asserts `=~ "0"` for `#preview-skipped-count`; the
  existing `extract_count/1` helper is precise.
- `import_live_test.exs:437` still refutes `id="inspection-modal"`, an id CL-24
  never used — that scope refutation is now vacuous too.
- `imported_message/1` uses `Map.get(summary, :skipped, 0)` where `summary.skipped`
  always exists.

## CL-26 — Histórico de importações — code review + QA (2026-09-20)

- `run_account_label(nil)` clause at `import_live/index.ex:668` is unreachable —
  the template's `:if={run.account}` already owns the nil case.
- The renamed "no dropzone is rendered" test still also refutes
  `id="inspection-modal"`, an id that is stale since CL-24 shipped `#inspect-drawer`.
  The name under-describes what it asserts, and the stale half refutes nothing.

## CL-25 — Dropzone universal — code review + QA (2026-09-20)

- **The reverse staging leak.** Spec review closed the "a drop replaces a drop"
  direction. The opposite direction remains: opening a CL-24 folder inspection
  while a drop drawer is open replaces `@inspect` without discarding `@drop`, so
  the drop's staging directory survives — including past closing the folder drawer,
  since `@drop` stays assigned. QA reproduced it and confirmed `terminate/2` does
  reclaim it. Non-blocking (no DB row affected, the stale drop can never be
  confirmed, bounded by `terminate/2` and the 24h sweep), but it is the same class
  of bug as the one already fixed, and the symmetric fix is small.
- **The `"no compatible account"` test never asserts the staging directory existed**
  before asserting it is gone. QA added the positive assertion and verified the
  behaviour is correct, but as shipped the test would not catch a regression that
  stops staging altogether — only one that stops cleaning up.
- `handle_event("validate_drop", …)` could cancel preflight-rejected entries so the
  single upload slot self-heals without needing a `Dispensar` click.
- A `stage_drop/3` I/O failure is reported to the operator as "Formato não
  reconhecido", which is misleading, and leaves the partially created hash directory
  to the sweep.
- `drop_upload_errors/1` is computed three times per render; an assign would be cleaner.

## CL-27 — Remoção dos modais legados — code review + QA (2026-09-20)

Two further losses that the spec's three-gap parity table did NOT name, both
found during implementation review rather than spec review:

4. **The batch modal's inline `update_cycle` due-day shortcut is gone.** The
   closing day / due day of a card remain editable in the account form, so the
   capability survives, but the one-click path from the import flow does not.
5. **`DirectoryImporter.Result.cycle_warnings`** (`directory_importer.ex:55`) is
   still produced and still unit-tested, but now has no consumer anywhere in
   `lib/` — the deleted batch modal was its only reader. Either surface it on
   `/imports` or drop the field; leaving a computed-but-unread warning is how
   a real signal goes unnoticed.

Coverage note: QA read all 23 deleted tests individually. Every one asserted
against the two deleted components. The two that also reached still-shipping
code keep independent coverage (`ingestor_test.exs` and
`directory_importer_test.exs` for the bb_csv save path;
`directory_importer_test.exs:246-280` for `cycle_divergences/2`). The
`:task_start_fn` hook the third exercised now has zero references in `lib/`, so
that test died with its code. No regression net was silently dropped.

## CL-16 — Redesenho de /categories — code review + QA (2026-09-20)

- **A parent-id cycle hangs `/categories` — pre-existing, app-wide, worth its own task.**
  With `A.parent_id = B` and `B.parent_id = A`, loading the page never returns
  (QA measured `:TIMED_OUT_HUNG` at 15s): it spins, with no raise and no stack
  overflow. The cause is the unguarded parent-chain walk in
  `Categories.link_parents/2` (`categories.ex:85`), reached from
  `list_categories/1`, which runs BEFORE CL-16's newly guarded
  `group_by_parent/1` (that one returns in milliseconds and drops cyclic rows).
  `full_name/1` (`category.ex:74`) walks unguarded too, though it terminated in
  QA's case. Not blocking CL-16 — the diff leaves `link_parents/2` untouched and
  no UI path can create a cycle — but the defect affects every caller, and a
  hang is worse than a hidden row. A depth cap or a visited-set guard is small.
- **A flattened deep descendant shows only its own name at child indentation**
  (`category_live/index.ex:281`), implying its root is its parent. `full_name/1`
  for rows whose `parent_id != root.id` would tell the truth about the hierarchy.
- **`?parent_id=` on `:new` still accepts a subcategory** as a parent option
  (`form_component.ex:68`), so "roots only" is not literally true of the query-string
  path. Harmless now that deep rows stay reachable, but it is the same hole the
  round-1 finding closed in the select.

## CL-17 — Central de Automações — code review + QA (2026-09-20)

- **The reapply tests depend on an unasserted insertion-order invariant.** The
  singular/plural `reapply_message/1` tests require the transaction to be inserted
  BEFORE the rule — create the rule first and the ingest-time applier categorises
  it, so the reapply delta is zero and the test legitimately fails. That fact is
  in a comment, not an assertion. Asserting the pre-state (transaction
  uncategorised) before clicking reapply would make the invariant self-explaining
  to whoever next touches the test.
- **No test pins the new href** at `lib/cash_lens_web/live/transaction_live/index.html.heex:116`,
  unlike its `transfer_live` counterpart, so that link can silently rot back to
  the legacy path.
- The spec named `layouts/app.html.heex` for the nav entry; it actually lives in
  `layouts.ex` / `nav_groups/1`. Corrected in the spec during this task.
- `layouts_test.exs` asserts a hardcoded nav-entry count, which has now moved
  twice in one session (15 → 16 by CL-23, 16 → 15 by CL-17). Asserting the path
  list instead would stop it breaking on every nav edit and would fail with a
  readable diff.

## Correction — the dev environment moved twice (2026-09-21)

**The test command recorded in the CL-24 entry above is obsolete.** It is left in
place because this file is append-only, but do not follow it. The environment
changed twice on 2026-09-21:

1. `refactor(dev-env): run against a bundled Postgres only` removed poli-runner
   mode and `poli-runner.yml`. The shared `poli-postgres` on host port **54321**
   is no longer what this project uses, so any instruction naming that port is
   wrong.
2. `refactor(dev-env): keep Postgres inside the compose network` stopped
   publishing the database port at all. Postgres listens on 5432 on the compose
   network only, so host-side `mix` cannot reach it either.

**The command is now:**

```sh
docker compose exec app mix test
```

`./run` remains the way to exercise the suite from the host: it starts its own
Postgres on the same named volume and publishes the port for as long as it runs.

Two things this surfaced, both fixed in that second commit:

- **The app image was stale**, running Elixir 1.16.3 / OTP 26 while the Dockerfile
  and the host were on 1.18.4 / OTP 28. Beyond the nuisance of host and container
  overwriting each other's `mix.lock` (Mix 1.16 does not record the `depth: 1` that
  `mix.exs` declares for heroicons), tests in the container were not exercising the
  version that ships. `docker compose build app` fixed it — worth checking after any
  Dockerfile change.
- **A test that cannot pass as root.** `omits an unreadable file without raising`
  chmods a file to `0o000` and expects the scan to skip it; root ignores permission
  bits, and the app container runs as root. Tagged `:requires_unprivileged_user`
  and excluded automatically when the suite runs privileged. The host run still
  exercises it.

The spec files under `docs/tasks/` were corrected in place rather than annotated,
since they guide work that has not happened yet. CL-28's spec additionally carried
an acceptance criterion requiring `poli-runner start cash_lens`, which nothing can
satisfy now that `poli-runner.yml` is deleted; it was replaced with a `./run`
criterion.

## CL-28 — Remove the Gemini CLI leftovers — code review + QA (2026-09-21)

- **Nothing provisions `assets/node_modules`, and the fix is not trivial.** It is
  gitignored, so a fresh clone cannot build the bundle until someone runs
  `npm install --prefix assets`. CL-28 tried to close this by adding an install to
  the compose `app` command and **it broke the host**: `.:/app` is a bind mount with
  no anonymous volume for `assets/node_modules`, so the install ran against the
  working tree, and `npm ci --omit=dev` deleted `playwright`. Reverted and repaired.
  The real fix needs a design decision — an anonymous volume for
  `/app/assets/node_modules` plus a build-time `npm ci` in the Dockerfile (the
  pattern the repo already uses for `mix.exs`/`mix.lock`), versus a runtime install
  — and deserves its own task with its own review.
- **`scripts/extract_mercado_livre.js:5` hard-codes
  `require('../assets/node_modules/playwright')`.** That relative reach into another
  directory's `node_modules` is what made the above fatal rather than merely
  annoying, and it will break again for any tooling that prunes that tree. The
  underlying oddity is that `playwright` is declared in `assets/package.json` while
  its only consumer lives in `scripts/`.
- A process note worth keeping: the developer's round-1 usage grep filtered to
  `*.ex,*.exs,*.sh,*.yml,*.md,*.json` and therefore never looked at `*.js`, which is
  exactly where the consumer was. When checking whether something is safe to remove,
  the file-type filter is the assumption most likely to hide the answer.

## CL-18 — Previsão de Caixa — spec review round 5 (2026-09-21)

The operator asked three questions rather than requesting changes. Two of the
answers became on-screen copy, following the CL-16 precedent. Review then caught
that the first draft of that copy was inaccurate in three ways — worth recording,
because copy that explains behaviour is worse than none when it is wrong:

- **"Itens editados à mão nunca são alterados" was absolute and false.**
  `Forecast.resync_item/1`, reached from the per-item `Ressincronizar com
  Histórico` action, deliberately overrides a `manually_edited` item and clears
  the flag. The claim is true only of `sync_all/0`, and is now scoped to it.
- **"últimos 6 meses" is not what the code does.** The window is
  `-30 * @history_months` = 180 days, which is not six calendar months.
- **The label did not match the screen it points at.** The copy said `Fixas`
  while `/categories` ships the flag as `Fixo (Contas Essenciais)` after CL-16.
  An instruction to go and mark something is only actionable if it names the
  control the operator will actually see.

One more worth a footnote in any future work on this: `median/1` returns the
**lower** middle value on an even-sized list (`Enum.at(list, div(length - 1, 2))`),
so with exactly two transactions the earlier day wins. It is not an average, and
it should not be "corrected" into one.

The third question — whether new installment purchases enter automatically — is
answered No, structurally: installment groups never become recurring items, and
`suggest_for_category/1` filters `a.is_credit_card == false`, so a card purchase
cannot feed one either way. The confusing part is that the lookalike case does
work: a financing debited monthly from a current account is an ordinary
transaction in a non-card account, so a Fixo category picks it up. That is why
the mock's `Financiamento do Veículo` is a fixed category and not a parcelamento.

## CL-18 — Previsão de Caixa — spec review round 6 (2026-09-21)

Round 6 exceeded the pipeline's five-round cap. That was the operator's explicit
decision, taken with the reason in view: the cap exists to break agent-versus-agent
loops, and rounds 4–6 were the operator iterating on their own design while the
automated review approved each time. Recording it so the override is visible.

The addition was "temporary recurrences" for installment commitments. What it
turned into is worth keeping:

- **The membership rule is the origin of the money, not the label.** A commitment
  is a temporary recurrence iff none of its transactions sits on a credit-card
  account — the same fact that decides whether `account_installment_total/2` folds
  it into a card bill. Deciding by `commitment_type` instead would let a mistyped
  row be counted twice. With this rule, bill-inclusion is a **strict subset** of
  ruler-exclusion, so double counting is structurally impossible; the worst case is
  a commitment shown nowhere, never one shown twice.
- **The parcel value must come from `Installments.parcel_value/1`**, which rounds
  the quotient to two decimals. The first draft said `total_amount / installments`.
  For a non-divisible plan those differ (1000/3 → 333.3333… vs 333.33), which would
  give the ruler a different amount, a different `Saldo após` chain, and a different
  figure from the one the card-bill disclosure shows for the same group. It would
  also have failed QA against a *correct* implementation.
- **The rule is a deliberate superset.** `card_accounts/0` also requires
  `not is_closed`, `closing_day` and `due_day`, so a commitment on a closed or
  unconfigured card is in no bill and on no ruler — invisible. Pre-existing, not a
  regression, recorded so it is not read as one.
- **`is_contemplated` changes nothing.** It is written by the consórcio form and
  read in exactly one display line; no projection code touches it. Contemplation
  draws the credit letter, but the parcels continue unchanged until the plan ends.
- **This addition displays nothing against today's data.** The database holds 73
  installment groups, all `credit_card`, all on card accounts — zero `financing`,
  zero `consorcio`. It starts paying off when such a commitment is first recorded.

One process note: an expected result demanded the end month on *every* temporary
event, but the final parcel's card sensibly marks itself as closing the commitment
instead, since it already sits in that month. The mock was right and the criterion
was wrong — worth remembering that a criterion QA reads literally can be the
defective half.

## CL-18 — Previsão de Caixa — code review + QA (2026-09-21)

- **The running-balance prominence test is weak** (`forecast_live_test.exs:127-136`):
  it matches `"text-lg font-black"` against the whole page and never against the
  amount on the same card, so it cannot catch the very inversion it is named for.
  The requirement itself holds — per card the amount is `text-xs font-bold` and the
  balance is `text-lg font-black` — but the test would not notice if that flipped.
- **`ForecastChart` in `assets/js/app.js:16-80` is now dead code.** The Chart.js
  trend card was removed to match the mock, so nothing carries the `phx-hook` and
  `@chart_data` is gone. The `Chart` import must STAY — it is still used at
  `app.js:363`. Left untouched deliberately: the file is outside this task's list.
- The critical point on the ruler is matched by date, so two occurrences on the same
  day both receive the badge (`forecast_live/index.ex:50-57`).
- `min_by`'s sorter uses `!= :gt`, so it replaces on ties and returns the *last*
  tied occurrence (`forecast.ex:241-246`).
- `@horizon_days 365` in the LiveView duplicates `Forecast`'s
  `@default_horizon_days`.

**A spec-authoring mistake worth not repeating.** When round 5 corrected the sync
copy (180 days rather than "6 meses", and scoping the no-change claim because
`resync_item/1` does override manually edited items), the verbatim copy block was
fixed but the matching Test Criteria line and expected result were not. The
developer spotted the contradiction and followed the verbatim block, which was
right — but QA reads `expected_results` alone and would have failed a correct
implementation on the stale wording. Corrected before QA ran. When copy is
specified in two places, both move together.

## CL-8 — respec pós-split — spec review (2026-09-21)

CL-8 came back to `backlog` after its seven children shipped, carrying the
original seven expected results that described the whole feature. The respec's
job was to find what genuinely remained. Review confirmed the scope is honest in
both directions — nothing invented to justify the task, nothing real declared
done — and that finding is worth recording, because a post-split respec can fail
either way and inventing work costs an implementation, a review and a QA pass on
nothing.

What remained were two cross-child seams that no single child owned, which is
exactly what belongs to a parent:

- **`Installments.scan_and_apply_all/0` never runs after a confirmed import on
  `/imports`.** It has three call sites — `directory_importer.ex:98`,
  `admin_database_live.ex:153` and its own definition — none in
  `import_live/index.ex`. This is CL-27's parity gap 1, deliberately deferred by
  that removal-only task.
- **The reverse staging leak.** `handle_event("inspect", …)` assigns `:inspect`
  without calling `discard_drop/1`, unlike `close_inspect` and `handle_progress`,
  so opening a folder inspection over an open drop drawer leaves the drop's
  staging directory behind. Found by CL-25's QA.

Correctly left OUT of CL-8 and still open as their own candidates: the one-shot
folder-wide import from the UI, bulk multi-file upload (`max_entries: 1` is CL-25's
design), and the fact that nothing provisions `assets/node_modules`. Those are new
capability or build infrastructure, not integration seams.

Two precision points fixed before the gate:
- **`scan_and_apply_all/0` is global.** It regroups every ungrouped transaction in
  the database, so its return can exceed what the current import contributed. Copy
  attributing the count to the imported file would be false whenever older
  ungrouped rows exist. The flash clause is now fixed wording, omitted at zero, so
  the criteria are exact string assertions.
- **The regrouping is not free**: it re-dates parcels and rebuilds account balances,
  and this puts that work inside the confirm handler.

Also settled: the original criterion "Forçar Download/Atualizar do Drive" is
satisfied by the existing rescan. There is no Google Drive API integration
anywhere and none was ever built — the two mentions in `lib/` are prose, and the
monitored folder is a locally-synced Drive mount that the Drive client keeps
current.

## CL-8 — costuras de integração — code review + QA (2026-09-21)

### A real data-corruption defect, found in passing — deserves its own task

**`CSVParser.extract_metadata_and_clean/2` (`csv_parser.ex:190`) lets any `dd/mm`
run inside a description hijack the transaction's date.** Verified by execution
against a 2026-09-21 base date:

- `"COMPRA LOJA PARC 03/10"` → date **2026-10-03**, description `"COMPRA LOJA PARC"`
- `"UBER 15/03 SAO PAULO"`   → date **2026-03-15**, six months into the past

Two losses at once: the date is silently relocated, and the matching text is
stripped from the description.

**Scope: `bb_csv` only.** The single call site is `csv_parser.ex:173`, inside
`do_parse_row/3`, whose only caller is `parse_bb_row/2` (`:144`). `parse_bradesco_row/1`
(`:63`) and `parse_mercado_pago_row/1` (`:289`) never reach it. An initial review
claim that all three CSV parsers were affected was wrong; QA traced the call site
and the narrower reading was confirmed.

It interacts with CL-8: the defect erases the `PARC n/m` marker from BB statements,
so the installment regrouping CL-8 just wired into the import path can never fire
for a BB CSV import. Pre-existing and independent — CL-8's own fixtures use an OFX
`<MEMO>`, which does not route through `CSVParser`, so the seam is exercised
against real production code rather than around the defect.

### Other notes

- `index.ex:1033` renders ` • 1 transações agrupadas` — plural with a singular
  count. The wording is spec-pinned so it was left alone; worth fixing when the
  copy is next revisited.
- `scan_and_apply_all/0` now runs **synchronously inside the confirm handler** and
  scales with the whole database's ungrouped backlog, re-running
  `rebuild_account_balances/1` per affected account. This is parity with the flows
  CL-27 removed, so not a regression, but it is a click that can stall on a large
  database. An Oban job is the fix if it starts to bite.
- Worth recording as method: this diff's tests were mutation-verified six ways,
  and the disjoint failures (breaking the folder arm killed only the folder test,
  breaking the drop arm only the drop test) are what proved the two arms are
  independently covered rather than one test passing through shared code.

## /imports cannot read a Google Drive folder from the container (2026-09-22)

The operator hit `Pasta não encontrada` on `/imports` for a real, populated
Drive folder. Two separate things, and the second is the one that decides the
answer.

**1. The container could not see the path.** `/imports` runs in `cash_lens-app-1`,
which has no bind mount for `/Users`, so the folder genuinely did not exist from
where the app was standing. The error was correct.

**2. Mounting it does not fix it.** With a read-only bind mount at the same
absolute path, the directory lists and the account folders resolve — and reading
a statement fails with **EIO**. Google Drive's CloudStorage files are placeholders
that macOS materialises on demand through the FileProvider framework, and a Docker
bind mount cannot trigger that. Observed directly: a `.account` read failed with
`eio` on one attempt and succeeded on the next, while
`extrato_bb-cc-2026-03.csv` failed outright. Intermittent read failure behind a
directory that lists is worse than the honest "folder not found", so the mount was
reverted rather than shipped.

**The answer is `./run`**, which runs the app natively where the FileProvider works.
Verified: `Imports.scan/1` returns 51 files across the six resolved account folders.
Documented in the README and in a comment where the mount would have gone, so the
next person does not re-add it.

**A mistake worth recording:** the first attempt put
`IMPORT_ROOT=/path with spaces` unquoted into `.env`. Compose tolerates that, but
`./run` does `set -a; . ./.env`, so the unquoted spaces broke it
(`./.env: line 7: Drive/Banco: No such file or directory`) — the script died before
starting Phoenix. `.env` here is read by two consumers with different parsing
rules; a value with spaces must be quoted for the shell one.

## Um caminho colado entre aspas era guardado com as aspas (2026-09-22)

The operator pasted the monitored folder path wrapped in double quotes — the way
it appeared in a chat message — and `/imports` kept reporting `Pasta não
encontrada` while displaying a path that looked exactly right. The stored value
was literally `"\"/Users/.../My Drive/Banco\""`: the quotes were part of the path.

`Imports.put_import_root/1` only did `String.trim/1`, so anything non-blank was
persisted verbatim. It now strips one matching surrounding pair of single or
double quotes and trims again, leaving an unquoted path and an unmatched leading
quote untouched. Six tests cover it; mutation-verified (bypassing the new step
produces four failures).

Worth noting why this is not an edge case: a Google Drive root almost always
contains a space (`My Drive`), and a path with spaces is exactly the kind people
quote when copying from a terminal, a document or a message. The failure mode was
also unusually confusing — the screen echoed back a path that read as correct.

**Two process notes from the same fix:**

- **I introduced a name collision.** The new helper was first written as
  `normalize_root/1`, a name already taken by a private function that
  `import_root/1` and `relative_path/2` depend on and that accepts `nil`. The
  suite caught it immediately (`String.trim/1` given `nil` in two unrelated
  tests). Renamed to `unquote_path/1`. Grep for the name before adding a private
  helper to a 560-line module.
- **The container was still serving :4444** while this was being diagnosed, which
  masked the question: the containerised app cannot read the Drive folder at all
  (see the preceding entry), so the quoted path was only one of two reasons it
  failed. Both had to go.

## Desligar o preview ao vivo do Pluggy (2026-09-22)

The operator was still seeing Pluggy's temporary, not-yet-imported transactions
and expected them gone. Worth recording what was actually true, since it was not
what either of us assumed:

- The earlier request had been to drop live entries from **Receitas/Despesas on
  the dashboard**, and that had been done. The dashboard was clean.
- **`/transactions` was never part of that conversation** and still merged them:
  263 live rows in the stream, and they were added to the screen's own total via
  `add_live_summary/2`. That is where the operator was seeing them.

Turned off by a config switch (`:pluggy_live_preview_enabled`, now `false`) that
simply does not start `LivePreviewCache`. Two properties make that sufficient,
and both were verified rather than assumed:

- Every reader already goes through a `safe_cache/2` that catches the exit from
  calling an absent process and falls back to no entries — that path existed for
  the test environment, where the cache is likewise never started.
- The one non-read caller, `refresh_now/1`, is a `GenServer.cast`, which returns
  `:ok` against a missing server instead of exiting. Had it been a `call`, the
  switch would have crashed two LiveViews instead of quietly disabling a feature.
  Three tests now pin both properties, so a future change from cast to call is
  caught here rather than by a broken screen.

**`pluggy_balance` is deliberately NOT affected.** It is read from
`pluggy_account_links` in the database, not from the cache, so "Saldo Atual"
still shows the bank's own figure (verified unchanged at R$ 26.461,63 with 6
linked accounts). If the operator later wants Saldo Atual back on the accounting
balance, that is a separate decision.

Related answer worth keeping: an account's balance is adjusted at **`/balances`**
("Saldos Contábeis"), per account and per month, via a modal that takes the real
statement balance and lets `BalanceAdjuster` compute the difference. For an
account linked to Pluggy with a `pluggy_balance`, that adjustment still drives
the monthly history and the charts, but the dashboard's Saldo Atual card comes
from Pluggy and ignores it.

## CL-29 — parser do extrato PDF do Mercado Pago — spec (2026-09-22)

The operator's Mercado Pago checking-account statements moved from hand-made CSVs
(their word: "gambiarra") to real PDFs. 20 samples, 01/2025–08/2026, 407 transactions.
What the spec rounds established is worth keeping, because most of it contradicts
what the first pass believed:

- **Descriptions are vertically centred around the transaction line.** A long one
  occupies lines ABOVE and BELOW; a short one sits on the line; and a third shape
  puts a fragment *between the date and the operation ID* with continuation on both
  sides. That third shape is the dangerous one — ignoring the middle fragment yields
  a description that looks plausible and is wrong.
- **Final measured shapes, after noise stripping** (the only count that means
  anything): `(0,0)` 381, `(1,1)` 22 — 4 of them with an inline fragment — `(2,2)` 4.
  26 multi-line across 13 of 20 files. **Max span 4 continuation lines, all symmetric.**
- **Two earlier counts were wrong, and one was mine.** I reported "up to 5 lines" and
  asymmetric "3+1 / 2+3" shapes; my measurement crossed block boundaries and absorbed a
  neighbour's line. A phantom `(1,0)` shape was the `1/2` page marker sharing a block
  with `14-11-2025 Rendimentos`. There is no `(1,0)`.
- **The form feed must be stripped as a CHARACTER, never as a line.** In
  `pdf_260922100902.pdf` it is prefixed to a transaction line itself
  (`"\x0c   14-11-2025   Rendimentos ..."`), so dropping lines containing `\f` deletes
  that transaction — one row in 407, R$ 0,04, invisible by eye. Caught only by the
  balance-chain oracle, which is the best argument for having the oracle. Reviewer
  reproduced it: simulating the wrong rule deletes exactly that row and nothing else.
- **The operation ID is NOT unique and must not become a dedup key.**
  `101754796278` appears on 08-02-2025 at R$ -48,51 and on 15-03-2025 at R$ 18,63 —
  a purchase and its refund sharing an order id. An earlier draft proposed it as a key;
  it would have silently discarded the refund.
- **Noise must be stripped positionally, never by content match.** One transaction's
  description continuation is the account holder's own name, which also appears in the
  document header (`02-02-2026`, `Transferência Pix enviada Heitor Luis Polidoro`).

Two process notes:

- **`:real_statements` must be excluded UNCONDITIONALLY**, not the way
  `:requires_unprivileged_user` is. That tag is dropped only when `euid == 0`, so it is
  excluded in the container and RUNS on the host — copying the condition would make the
  opt-in test run on every host run and fail for anyone without `CASH_LENS_MP_PDF_DIR`.
- **The Drive folder and the test runner are in different worlds**, a direct consequence
  of two changes made earlier the same day: the container deliberately does not mount
  Drive, and Postgres is not published to the host. The suite CAN run on the host, but
  only while `./run` is up. That precondition is now stated inside the expected result
  itself, because QA reads nothing else.

Also cleaned up: the `live_preview_switch_test.exs` I committed in 94225af added 2 credo
findings (nested modules not aliased), taking the baseline from 23 to 25, while that
commit claimed none were added. Fixed; back to 23.

## [CL-29] Criar parser do extrato PDF da conta corrente Mercado Pago — 2026-09-22

- `mercado_pago_pdf_parser.ex:87` — if `DETALHE DOS MOVIMENTOS` is absent,
  `drop_while/2` consumes the whole stream and `parse/2` returns `[]` silently.
  That is the same "content disappears without a signal" failure mode the
  zero-transaction-block raise exists to prevent, one level up. The detector
  makes it unreachable in production today, but a `raise` (or at least a
  `Logger.warning`) when the marker is missing would close the gap for the cost
  of three lines. Non-blocking.
- `mercado_pago_pdf_parser_test.exs:239` — `assert message =~ "sem linha de
  movimento"` reads at a glance like an assertion that the *raise message* is
  Portuguese; it is actually fixture text echoed back. Worth also asserting the
  English `"block with no transaction line"` so the test pins both halves and
  the intent is unambiguous.
- `ingestor_test.exs:672-682` — the second half of
  `"expected_extensions/1 offers only PDFs to a mercado_pago_pdf folder"`
  re-implements `Path.extname/1` filtering inside the test rather than calling
  the production folder-scanning path, so it largely asserts that `Enum.filter`
  works. The first line of that test (`== [".pdf"]`) already carries the real
  contract. Harmless, but it is the one place where an assertion does not earn
  its keep.
- `docs/tasks/CL-29-spec.md:186-188` still describes the fixtures as having
  "operation IDs and monetary values replaced by invented ones", which deviation
  (a) knowingly reverses. Consider a one-line spec amendment so the document
  matches what was shipped and the next reader does not read the fixtures as a
  violation.
- `transaction_blocks/1` is public solely so the corpus test can assert
  structural properties. This is documented in its `@doc` and is the honest
  choice over reaching into private functions, but it does widen the module's
  public surface for a test-only consumer. Fine as is; flagging only so the
  decision stays visible.

## [CL-29] Criar parser do extrato PDF da conta corrente Mercado Pago — 2026-09-22

- `transaction_blocks/1` is public solely so the opt-in corpus test can assert
  structural properties (shape distribution, page-break containment). That is
  documented in the `@doc`, which is the right mitigation, but it does widen the
  module's production surface for a test-only need. If the API ever needs
  tightening, `@doc false` plus a `@moduledoc`-level note, or moving the shape
  helpers into the test with a private re-implementation, would keep the
  contract narrower. Non-blocking — the current form is documented and honest
  about why it exists.
- `parse/2` uses a default argument (`_format \\ :mercado_pago_conta`) on an
  `@impl true` callback, which also defines an unused `parse/1` arity. Harmless
  and consistent with how the module is called, but the default is never
  exercised; dropping it would make the behaviour contract exactly one arity.
- The four committed multi-page/shape fixtures encode the account holder's real
  name. That is deliberate and load-bearing for result 6 (the content-collision
  case), so it should stay — worth noting only so a future cleanup pass does not
  "anonymise" it and silently destroy the test's point.

## [CL-30] Speed up the transactions screen by removing per-row work from render — 2026-09-23

- Expected results 7 and 8 pin the base as the literal hash `a84f268`. If the branch
  is ever rebased onto a newer `master`, that hash stays valid as a reachable commit
  (the range just widens to include anything pulled in), but the table and the
  `app.js` diff could then pick up unrelated files. Not blocking — it only makes the
  criteria stricter, never laxer — but implementing on a branch cut directly from
  `a84f268` and not rebasing before QA keeps the ranges tight.
- The spec's note about the DaisyUI focus-based dropdown possibly closing across a
  `stream_insert` row patch (lines 55-61) asks for the chosen approach to be recorded
  in the measurements doc, but no expected result checks that record. It is a design
  note rather than an acceptance criterion, so this is fine as-is; just be aware QA
  will not catch its omission.
- Expected result 6 fixes the "after" bar as "lower than 24.3 ms" with no margin. A
  median-of-7 run that lands at 24.2 ms would pass while representing no real win.
  Naming a target (the design removes ~150 queries per 50 rows, so a large drop is
  expected) would be a stronger gate, but the current wording is still mechanically
  decidable, so it is not blocking.

## [CL-30] Speed up the transactions screen by removing per-row work from render — 2026-09-23

- `index.ex:940` — consider clearing the whole memo (`assign(:installment_suggestions, %{})`)
  in `link_installment` / `unlink_installment` instead of deleting one key. A group's
  `paid_count` changes when *any* of its parcels is linked, so sibling transactions' memoized
  `next_installment` can be one behind after a link. Not a regression (the old render-time code
  left the same stale label in the DOM, since unrelated stream rows are not re-rendered) and
  not what the spec asked for, but the whole-memo reset costs one line and at most one
  re-query per row, and removes the staleness class entirely.
- `index.ex:196` — on a memo *hit* the handler still runs `get_transaction!/1` plus
  `annotate_one/1` (category-suggester and pluggy-matcher queries) before the `stream_insert`.
  Those are not `installment_groups` queries so the memoization test is right to pass, but the
  second open of a menu is not as free as "memoized" suggests. Only worth doing something about
  if menu-opening ever shows up in a profile; the current shape is the simpler code and the row
  does need to be re-streamed to carry the suggestion.
- `index_installment_suggestion_test.exs:104` — the zero-query test drives the re-render through
  `render_click(live, "clear_filters", %{})`. That works, but it couples the assertion to an
  unrelated event's behaviour; if `clear_filters` ever stops forcing a full stream reset the
  test would keep passing while testing less. A comment naming *why* `clear_filters` is the
  chosen re-render trigger (it resets the stream) would keep that intent from eroding.

## [CL-30] Speed up the transactions screen by removing per-row work from render — 2026-09-23
- The measurements doc's "How these numbers were taken" section states `./run` was live and the compose stack deliberately not started; at verification time the situation is the reverse (compose up, `./run` down). The numbers remain internally consistent and the criteria do not pin the harness, but a one-line note about which environment a future re-measurement should use would prevent someone re-running the harness against the wrong postmaster.
- `docs/tasks/CL-30-measurements.md` cites `index.html.heex:821` as the old call site; line numbers drift. Quoting the removed expression instead of the line number would age better.
- The "Buscando sugestão..." placeholder renders for every unopened row (`installment_suggestion == :not_loaded`) inside the dropdown content. It is invisible until the menu opens, so this is cosmetic only, but a brief spinner-free empty state would avoid a flash of that text on slow replies.

## [CL-33] Introduce a cash-accounts scope for the global screens — 2026-09-23

- Drop the "returns hits only inside `suggest_for_category/1`" exclusivity
  clause from the forecast half of criterion 2, or exempt comment and `@doc`
  lines from it. Criterion 3 already forbids `Scopes.` in the card-bill code,
  which is the containment that matters; the surviving clause can only fail a
  correct implementation that chooses to mention the scope in the
  `suggest_for_category/1` docstring. Not worth a revision round on its own —
  fold it in if the spec is touched again for another reason.
- If QA for CL-33 is ever run in a later session rather than immediately after
  implementation, re-check that
  `.meridian/reports/CL-33-in_progress-1.md` still exists before relying on
  criteria 5 and 12; `.meridian/` is gitignored and pruned to the 50 most
  recent files.
- Consider having the implementer note, in the task report, the pre-change
  `grep -c "is_credit_card" lib/cash_lens/forecast.ex` value of 3 alongside the
  post-change 2. It makes criterion 7's expected figure self-evidently a
  consequence of removing exactly one predicate rather than a bare constant.

## [CL-33] Introduce a cash-accounts scope for the global screens — 2026-09-23

1. `lib/cash_lens/transactions.ex:469` and `:651` — consider "Considers only cash
   accounts, i.e. accounts that are not credit cards (see
   `CashLens.Accounts.Scopes`)". The current wording satisfies the criterion but
   tells a reader of the function less than the sentence it replaced.
2. `lib/cash_lens/accounts/scopes.ex:41-54` — the `@doc` for
   `cash_accounts_only/1` could state that the join alias is fixed
   (`:cash_scope_account`) and that applying it twice to the same query raises.
   The failure is loud, so this is documentation, not a fix.
3. `test/cash_lens/installments_scope_guard_test.exs` — `Installments.list_off_card_groups/0`
   is the other Installments query whose meaning a leaked scope would invert (its
   subquery asserts `a.is_credit_card == true`), and nothing guards it. The spec's
   test criteria did not require it; worth a follow-up alongside CL-31/34/35,
   which are the tasks that will actually be tempted to spread the scope.
4. `test/cash_lens/accounts/scopes_test.exs:17-22` — the exclusion test would also
   pass against a scope returning nothing. Adding a bank-account control row to
   that same test would make it self-falsifying instead of relying on its siblings.

## [CL-33] Introduce a cash-accounts scope for the global screens — 2026-09-23

- `cash_accounts_only/1` always adds an `:inner` join under the fixed binding
  name `:cash_scope_account`. Calling it twice on the same query would raise on
  the duplicate alias. That is fine for every current call site (each calls it
  once, and the two-binding case correctly uses `cash_account_binding/2`), but a
  one-line note in the `@doc` saying the function is not idempotent would save a
  future caller a confusing compile error.
- `test/cash_lens/forecast_scope_guard_test.exs` derives its fixture from
  `Date.utc_today()`. It is correct today and around month boundaries as written,
  but a frozen date would make it fully deterministic and immune to a future
  calendar-edge surprise. Not blocking — the `:estimado` branch is forced by
  construction, not by luck of the date.

## [CL-31] Make the month closing screen a cash-basis view — 2026-09-23

- Criterion 7's absolute money figures are measured against a dev database the
  operator keeps importing into; a back-dated import invalidates them without any
  implementation defect. Consider leading with the invariant ("the month
  breakdown total equals the same month's entry in `get_historical_summary/1`,
  and a `Cartão de Crédito` row equal to that month's bill payments is present")
  and treating the absolutes as the values measured at spec time, to be
  re-measured if dev data moved.
- Criterion 6 leaves the new filter key's literal name to the implementer. Naming
  it in the spec (e.g. `"cash_accounts_only" => "true"`) costs nothing and keeps
  the LiveView call site and any future caller consistent.
- `excluded_cash_summary_category_ids/0` is named for the cash *summary*, and
  `get_month_category_breakdown/2` becomes a second, differently-shaped consumer.
  Reusing it is correct — the set is exactly right and duplicating it would be
  worse — but a future reader may read the name as "this function belongs to the
  summaries". A one-line comment update on the helper naming its new consumer
  would prevent that, and is already permitted by Files-touched's "update both
  function docstrings" latitude.
- Files-touched requires `excluded_report_category_ids/0` byte-for-byte while
  criterion 8 forgives comment edits on it. Harmless (the criterion is the looser
  gate), but aligning the two wordings removes a needless question at QA time.

## [CL-33 follow-up] Wrong function name in Accounts.Scopes moduledoc — 2026-09-23
- `lib/cash_lens/accounts/scopes.ex` names `CashLens.Accounts.list_credit_card_accounts/0`
  in its moduledoc. That function does not exist; the real one is
  `CashLens.Accounts.list_credit_cards/1` (`list_bank_accounts/0` in the same
  sentence is fine, it has a default arg). Harmless at runtime, but it already
  propagated: the first CL-34 spec copied the wrong name into an acceptance
  criterion, which would have failed a correct implementation with
  UndefinedFunctionError. Found by the CL-34 spec review.

## [CL-34] Restrict the Extrato Geral screen to cash accounts — 2026-09-23

- **Restrict-by-default remains the architecturally better answer, and this is the gate
  to say so.** My round-1 position stands unchanged. The decision this task implements
  is that global screens must not show card rows; an opt-in key makes the safe
  behaviour the one every future caller has to remember to ask for. Every new global
  screen is one forgotten key away from silently regressing, and nothing in the test
  suite would catch it. The defensible counter is real and is the reason I am not
  blocking: `list_transactions/3` and `count_transactions/1` are genuinely shared with
  the JSON API, the reimbursement screens and the reimbursement-link component, all of
  which must keep seeing card rows, and inverting the default would touch all of them
  in a task scoped to one screen. If the operator accepts the opt-in seam, the
  follow-up worth filing is a narrow one: give the screen-facing callers their own
  function (or make the key's absence an explicit `:all_accounts` opt-out) so the
  default stops being "unrestricted by silence".
- Criterion 1 could hand QA the check instead of the property: e.g. state that
  `list_all_transactions/1` spans from its `def` to the next top-level definition and
  that no `@@` hunk range in `git diff --cached -U0 -- lib/cash_lens/transactions.ex`
  may intersect it. Adding `*.ex diff=elixir` to `.gitattributes` would also put the
  function name directly in the hunk header for every future task — worth doing as
  repository hygiene, out of scope here.
- Criterion 8's "this task's test files" would be tighter as an explicit allow-list
  (`test/cash_lens/transactions_test.exs` and any file under
  `test/cash_lens_web/live/transaction_live/`), matching the precision of the lib-file
  half of the same criterion.
- Criterion 2 leaves the filter map shape implicit; naming `"date_from"` / `"date_to"`
  would remove the one inference step QA has to make.
- Criterion 3's unkeyed-vs-joined-SQL comparison holds only while no transaction has a
  null `account_id` (verified: 0 today). If that ever changes, the criterion would fail
  a correct implementation. A one-line note would make the assumption explicit.
- The moduledoc of `lib/cash_lens/accounts/scopes.ex` still names
  `CashLens.Accounts.list_credit_card_accounts/0`, which does not exist. Correctly out
  of scope for CL-34, but it has now misled one spec and will mislead the next — worth
  a trivial follow-up.

## [CL-35] Restrict the Saldos Contábeis screen to cash accounts — 2026-09-23

- Criterion 4's second substring, `"— veja a tela de"`, is contiguous only if the
  implementer keeps the text up to the `<a>` on a single source line, as the mock does.
  I confirmed by rendering both shapes that HEEx preserves a source newline plus indent
  verbatim, so markup wrapped right after the em dash would render
  `"aqui —\n  veja a tela de"` and fail the literal check despite being a correct
  implementation. `mix format` and the mock both push toward the passing shape, so this
  is a hazard rather than a defect — not worth a revision round. If the criterion is
  ever touched again, extending the spec's existing "one uninterrupted text node"
  requirement (spec:66-68) to cover the run through `de` would close it outright.
- Criterion 6 dereferences `element["account"]["id"]`. `serialize/1` emits
  `account: nil` when the preload is absent, which would raise rather than fail cleanly.
  Harmless here — the sandboxed test owns only its two fixture rows, both with accounts —
  but writing the assertion over `get_in(el, ["account", "id"])` would degrade to a
  readable failure instead of a `nil["account"]` crash.
- Criterion 11 scopes credo to the four `lib/` files and leaves the three test files
  unchecked. Consistent with the measured baseline and correct as written; noting only
  that new test code ships without a style gate.

## [CL-34] Restrict the Extrato Geral screen to cash accounts (restrict-by-default) — 2026-09-23

- **Criterion 8's "uninterrupted text" versus the HEEx formatter.** The mock
  (`docs/tasks/CL-34-mock.html:26-27`) wraps the phrase across a source line
  break: `Compras no cartão de crédito não` / `aparecem aqui`. Rendered HTML then
  contains a newline mid-phrase, and `mix format --check-formatted` (criterion 15)
  will reflow long text inside the `<p>` back to that shape. Nothing here fails a
  correct implementation *if* the test normalises whitespace before asserting —
  which is what I would do — but the developer should be aware that a naive
  `render(view) =~ "Compras no cartão de crédito não aparecem aqui"` may fail on
  formatting alone. Suggest the test assert against
  `String.replace(html, ~r/\s+/, " ")`, and that QA read the criterion that way.
- **No criterion covers the `matches_filters?/3` account check** that the Approach
  requires. An implementation that skips it passes all 16 results while a
  transaction re-assigned to a card account from the transaction form stays in
  the stream until reload. The blast radius is one transient row from the user's
  own action — `/transactions` subscribes only to `"categories"` (index.ex:16)
  and the `:transaction_saved` messages originate from this screen's own
  components, so there is no cross-screen PubSub path that could surface card
  rows. Not worth a revision round, but a cheap criterion would be: "a LiveView
  test on /transactions moves a visible transaction to a credit-card account and
  asserts its description is absent from the rendered page without a reload."
- **Criterion 1's grep half is already true today.** `grep -n "Scopes\."
  lib/cash_lens/transactions.ex` returns 4 pre-existing hits (lines 633, 656,
  1358, 1385), so that half of the criterion cannot fail. The `git diff --cached`
  half carries all the weight; QA should judge on it.
- **Criterion 4 phrases `get_filtered_summary/1` as excluding "the card row".**
  That function returns `%{income:, expenses:}`, not rows; the test must assert
  the card transaction's amount is absent from the totals. Verifiable, just
  loosely worded.
- **Ordering with CL-35 on `scopes.ex`.** The two edits can land in either order
  without a code conflict (both are moduledoc prose, no code change), but if
  CL-35 lands first with a sentence already naming both contexts, CL-34 may have
  nothing left to add and `scopes.ex` would be absent from its staged diff.
  Criterion 13's "lists only:" reads as an upper bound, so an absent file is not
  a violation, and criterion 12 asserts file *state*, which an unchanged file can
  satisfy. Worth QA knowing so an absent `scopes.ex` hunk is not treated as a
  miss. Criterion 12's "no code change, only moduledoc text" is verifiable by
  reading the staged hunks for that file.
- **Stale moduledoc reference.** `scopes.ex` currently names
  `CashLens.Accounts.list_credit_card_accounts/0`, which does not exist (the real
  function is `list_credit_cards/1`). The spec already notes this and correctly
  keeps fixing it out of scope; since this task edits that moduledoc anyway,
  correcting the name in the same hunk would be nearly free.

## [CL-35] Split the consolidated total into cash and card debt — 2026-09-23

- Portuguese pluralisation of the footer counts (`1 conta` / `1 cartão` vs
  `1 contas` / `1 cartões`) is a real defect, but it predates this task
  (index.ex:157 already says `{@totals.count} contas` unconditionally) and it
  affects labels beyond this footer. Track it as its own small task rather than
  widening this diff; if the operator would rather have it now, the cleanest
  amendment is to change criterion 2 and 3 to assert the count digit and the
  element id separately from the noun, e.g. assert the cash row matches
  `~r/TOTAL EM CONTAS \(1 contas?\)/`, so a correctly pluralised implementation
  and the current wording both pass.
- Criterion 3 says "in one and the same month" without naming which month. The
  `/balances` mount defaults the filter to the current month/year
  (index.ex:277–282), so the fixtures must be inserted at `Date.utc_today()` for
  the rows to appear — as the existing test at balance_live_test.exs:82 already
  does. A wrong choice makes the test fail loudly rather than pass falsely, so
  this is not blocking, but naming the current month in the criterion would save
  a debugging cycle.
- Criterion 9 refers to `CashLens.Accounting.list_balances/3`; the call site uses
  the default-argument form `list_balances(filters)`. `def list_balances(filters
  \\ %{}, page \\ 1, page_size \\ 20)` does generate /3, so the reference is
  correct, but /1 is what `/balances` actually calls — worth keeping in mind when
  reading the criterion.
- The card footer keeping the stored negative sign is the right call and the
  spec argues it well (the footer must agree with the column above it). If the
  operator later prefers a positive "amount owed", that is a label-and-sign
  change to make deliberately, not a detail to slip in during implementation.

## [CL-34] Split the transactions summary into cash and card figures — 2026-09-23

- Criterion 9's fourth check, `git diff --cached -U0 -- lib/cash_lens/transactions.ex
  | grep "^-" | grep "Scopes.cash_accounts_only"`, treats a moved or reformatted
  line as a deletion. The exposure is narrow (only an edit to lines 633/656/1358/1385
  can produce it, and those regions are out of scope), so it does not block — but a
  future revision of this pattern could be made move-proof by requiring that any such
  `-` line also appear as a `+` line in the same diff, or simply by comparing
  `grep -c` before and after.
- Criterion 9's first check fails on any *added* line containing the literal
  `cash_accounts_only`, including a prose `@doc` line. The spec asks the new `@doc`
  to state the function is "deliberately **not** scoped to cash accounts"
  (spec:134-136); an implementer who phrases that as "not `Scopes.cash_accounts_only`"
  trips the check. Worth a one-line note in the spec telling the implementer to phrase
  that doc sentence without the literal identifier.
- Criterion 3's psql query has no account-kind-independent guard against the live
  preview contributing to the rendered figures. It happens to be safe today because
  `pluggy_live_preview_enabled` is `false` (config.exs:20), so the strip shows DB rows
  only — but if the operator re-enables the preview before QA runs, the browser figures
  and the query will diverge. A parenthetical "(with the Pluggy live preview disabled,
  as it is by default)" would make the criterion self-contained.

## [CL-32] Stop counting reimbursement pairs on the month closing screen — 2026-09-23

- Criterion 6: say explicitly that the 2026-09 observable is read **after**
  this task's change is applied. The pre-change, pre-CL-31 value is 25076.48,
  R$ 45,50 from the 25030.98 branch, so a QA who samples the observable too
  early would report "any other pair" on a correct implementation.
- Criterion 8 / the drill-down: if CL-31 has landed, `load_row_transactions/2`
  must pass the new reimbursement key **in addition to** CL-31's cash-accounts
  key. The Approach's "remove nothing CL-31 added" is written about the two
  breakdown functions; an explicit clause in criterion 8 would make the
  requirement local instead of relying on CL-31's own suite test.
- Name the new filter key in the spec (e.g. `"exclude_reimbursed"`). Criterion
  9 currently says "the new key" / "the exclusion key", which is verifiable
  only by reading the test the same task wrote; a fixed name also documents
  that it is not CL-31's key.
- `reimbursement_link_key` is typed `Ecto.UUID`
  (`lib/cash_lens/transactions/transaction.ex:14`), so the new fixtures must
  set a valid UUID — an arbitrary string will fail the cast rather than the
  assertion, which is a confusing failure mode to debug.
- Criterion 10 names only `live_preview.ex` and `category_suggester.ex` as
  dirty-but-unrelated. The tree also carries modifications to
  `test/cash_lens/pluggy/live_preview_test.exs`,
  `test/support/fixtures/credit_cards_fixtures.ex`, `docs/suggestions-log.md`
  and deletions under `.gemini/`, plus `CLAUDE.md` and `GEMINI.md`. The
  closed whitelist already excludes all of them, so this is cosmetic — but
  naming the whole dirty set would make the criterion self-evidently safe.

## [CL-31] Make the month closing screen a cash-basis view — 2026-09-23
- `lib/cash_lens/transactions.ex:809-819` — `exclude_transactions_with_cash_children/1` is a
  near-verbatim copy of `exclude_transactions_with_children/1:793-803`, differing only by the
  `|> Scopes.cash_accounts_only()` pipe. A single private builder taking the scoped/unscoped
  subquery (or `exclude_transactions_with_children(query, subquery)`) would remove the
  duplication. Non-blocking: the duplication is 8 lines, the comment above each explains why two
  variants exist, and keeping them separate is arguably what protects
  `query_historical_category_totals/0` from a future edit meant for the month screen. Deliberate
  duplication with a stated reason is acceptable here.
- `lib/cash_lens/transactions.ex:277-280` — `filter_cash_accounts_only/2` accepts both `true` and
  `"true"` while the only caller passes the boolean. Harmless (it mirrors the string-keyed filter
  map convention of the neighbouring filters) but the string arm is currently untested and
  unexercised; the test only covers `true` and the absent key.


## [CL-31] Make the month closing screen a cash-basis view — 2026-09-23

- The `index_coverage_test.exs:170` failure listed as "known" in the acceptance criteria no longer reproduces (file passes clean in isolation and in the full run). Worth removing it from the project's known-failures list so it does not mask a real regression later.
- `exclude_transactions_with_children/1` and `exclude_transactions_with_cash_children/1` now differ by a single scope call. A shared private builder taking the scope as an argument would make the divergence explicit and harder to re-merge accidentally — the same class of mistake criterion 4 guards against.

## [CL-35] Group the balances screen into cash and card blocks — 2026-09-23

- `expected_results[4]` compares the cash total against
  `... where not a.is_credit_card`, which is an inner join and therefore
  excludes any orphan balance — while the UI, per the Classification rule,
  renders orphan rows *inside* the cash block and includes them in its total.
  With 0 orphans on the dev database the two agree today, and
  `expected_results[1]`'s count uses the un-joined `balances` table, which is
  right. If an orphan balance ever appears, criterion 5's cash half would fail a
  correct implementation. Worth remembering at QA time; not worth a revision
  round now.
- `expected_results[7]` ("when the account filter selects a credit-card
  account... contains neither ... nor the heading text `Contas` as a block
  title") leans on the qualifier "as a block title" to avoid colliding with the
  word "Contas" elsewhere on the page (sidebar/nav, filter labels). The id
  checks in the same criterion (`balances-cash`, `balances-totals-cash`) already
  carry the assertion unambiguously, so the prose clause is redundant rather
  than harmful. It could be dropped or restated as "no element with id
  `balances-cash-title`" in a later pass.
- The `N contas` / `N cartões` labels count rows, not distinct accounts, so a
  multi-month filter reads e.g. "2 contas" for one account. The spec names this
  as pre-existing and puts it Out of Scope, which is the right call; noting it
  so it is not rediscovered as a defect during QA of this task.

## [CL-32] Stop counting reimbursement pairs on the month closing screen — 2026-09-23
- `filter_out_reimbursement_linked/2` and `filter_cash_accounts_only/2` now share an identical
  `when flag in [true, "true"]` guard and catch-all shape. Two occurrences is below the threshold
  where I would ask for an extraction, but if a third opt-in flag arrives, a small
  `truthy?/1` helper would be worth it. Non-blocking.
- The equality that is the *point* of this task — month screen totals equalling
  `get_historical_summary/1` for the same month — is currently pinned only by the dev-database
  figures in the spec (32765.42 / 45297.00 for 2025-08), not by any automated test. A fixture-level
  test asserting `sum(get_month_category_breakdown(y, m)) == get_historical_summary()[{y,m}].expenses`
  for a synthetic month containing a reimbursement pair would make that invariant regression-proof
  and would catch a future divergence in either direction. Non-blocking, and arguably better placed
  as its own follow-up than bolted onto this diff.

## [CL-32] Stop counting reimbursement pairs (QA) — 2026-09-23

- The dev-data reconciliation in criteria 5 and 6 rests on the two legs of each 2025-08 pair being near-equal but not equal (32177.46 credits vs 31277.46 debits, a 900.00 asymmetry across 7 pairs). That is consistent with partial reimbursements and is not a defect in this change, but if the intent is that a linked pair always nets to zero, a data-integrity check or a report of asymmetric pairs would surface any mis-linked rows that this exclusion now hides from both KPI cards. Non-blocking, and out of scope for CL-32.

## [CL-34] Split the transactions summary into cash and card figures (QA) — 2026-09-23

- Deep links to `/transactions` in the shape the period select emits do not activate the filter on
  a fresh load: `normalize_period/2` runs only on the `apply_filters` event, so
  `/transactions?period=2026-06` renders unfiltered and without the summary strip, while
  `?year=&month=` works. Pre-existing and untouched by CL-34, but it means a URL copied out of the
  screen's own control does not reproduce the screen. Worth its own task if deep links are meant to
  be shareable. Non-blocking.

## [CL-35] Split the consolidated total on Saldos Contabeis (QA) — 2026-09-23

- The totals labels pluralise unconditionally: filtering to a single account renders
  `TOTAL EM CONTAS (1 contas)` / `TOTAL EM CARTÕES (1 cartões)`. Both strings are frozen verbatim by
  the spec and pinned by the expected results, so the delivered behaviour is correct; a follow-up
  could make the noun agree with the count. Non-blocking.
- `calculate_totals/1` now runs twice per render over two disjoint lists. A single reduce producing
  both accumulators would halve the traversal. Immaterial at the current page size of 20; worth
  revisiting only if the page ever grows. Non-blocking.
- Dropping `phx-update="stream"` means both tables are re-sent on every filter change. Intended for
  this screen, which has no pagination control, but worth remembering if pagination is added later.
- Expected result 15 was unsatisfiable as written: it required `grep -n "is_credit_card"
  lib/cash_lens/accounting.ex` to be empty, but that file has carried one such reference since commit
  `1924ee0` — line 403, inside `get_historical_balances/1`, not `list_balances/3`. The criterion's
  intent (no cash-account restriction added to `list_balances/3`) was verified and holds. The defect
  class is a criterion that greps a whole file to assert something about one function; a criterion
  should be scoped to the function it is about, and should be checked against the current tree at
  authoring time.

## [CL-38] Pin the dashboard query count with a test, and explain it — 2026-10-11 (spec_review round 0)

- "Measurements on real data are taken against the development database" does
  not say how to reach it. `AGENTS.md` lines 119–138 document that `./run` and
  the compose `db` share one data directory and that starting the second while
  the first is live required a `pg_resetwal` recovery on 2026-09-22. The spec
  should name the connection form the way `CL-30-measurements.md` does
  (`DATABASE_HOST=localhost DATABASE_PORT=5432 …` against the live `./run`
  Postgres, after `pgrep -f 'bash ./run'`), and state that the measurement is
  read-only.
- Expected results 4 and 5 each assert three independent things in one line
  ("attributes every group" / "gives the formula" / "states six section costs";
  "records the baseline" / "separates inherent from defect" / "states the
  taildash consequence"). They are checkable, but a QA failure on one clause
  reads as a failure of all three. Splitting the weakest clause out of each — or
  rephrasing as "the document contains the following sections: …" — would make
  the contract read cleanly.
- Expected result 6 is self-grading: "every defect the document judges worth
  fixing" is satisfied trivially by a document that judges nothing worth fixing.
  The spec's prose already requires a written reason for each defect left
  unfixed; naming the two large groups (the `installment_groups` fan-out and the
  per-due-month `credit_card_statements` lookups) as defects that must each be
  adjudicated explicitly would close the loop without pre-judging the verdict.
- `test/cash_lens_web/controllers/dashboard_limit_test.exs` already renders
  `GET /` and asserts the 12-month limits with 2025/2026 date literals. The spec
  correctly refuses to repeat that pattern; a one-line pointer in the new test
  explaining why its dates are relative would stop the next reader from
  "harmonising" the two.
- The spec says `test/support/fixtures/*.ex` may be extended "only if … extend,
  never repurpose". Worth noting that `test/support/fixtures/credit_cards_fixtures.ex`
  is already modified in the working tree; the implementer should rebase that
  change out of their diff view before deciding what the factories cannot express.


## [CL-38] Pin the dashboard query count with a test, and explain it — 2026-10-11 (spec_review round 1)
- Expected result 6 now carries three distinct assertions (two-column baseline,
  inherent-vs-defect split, taildash consequence). It is verifiable as written,
  but splitting the taildash sentence into its own line would make a partial
  failure easier for QA to report without pushing the list over eight.
- Test criteria could name the concrete command used for the ">= 1 fails when
  fixtures are removed" check, so the falsification step is reproducible rather
  than described.

## [CL-38] Pin the dashboard query count with a test, and explain it — 2026-10-11 (code_review round 0)

* `query_counter.ex:56` — `:ets.new(:query_counter, [:set, :public])`. Because
  the handler only writes when `self() == owner`, every write comes from the
  owning process, so the default `:protected` would do and would state that
  invariant in the table's own options. Harmless as it stands.
* The document's **Finding 5** is an honest and correct record that the spec's
  test criterion "deleting the fixture rows that feed any one of the seven tables
  makes that table's `>= 1` assertion fail" cannot hold against today's
  controller — `closed_without_statement/0` and `list_off_card_groups/0` query
  their tables unconditionally, and the tally counts queries issued, not rows
  returned. Satisfying that criterion literally would require a `lib/` change,
  which the task forbids. The lower bounds are still worth having for the reason
  the finding gives, and the Expected Results clause they answer ("both `>= 1`
  and `<= ceiling`") is met. Flagging it so the gap between spec prose and
  reality is adjudicated deliberately rather than discovered in QA.
* Expected result "`mix precommit` passes" is **not** met, and the document says
  so under "What this task could not do". I verified all three causes predate
  this task (`lib/cash_lens/imports.ex:136` ungrouped clauses breaking
  `compile --warnings-as-errors`, ~23 pre-existing `credo --strict` findings in
  `lib/`, and the two date-dependent test failures above), and all three live in
  files this task is barred from editing. CL-43 exists for them. Not blocking on
  my side, but it is the one Expected Results checkbox that cannot be ticked, and
  QA should be pointed at CL-43 rather than at this change.
* `test/support/fixtures/credit_cards_fixtures.ex` is modified in the working
  tree and left unstaged. It is not needed (item 1 above), so the cleanest
  outcome is to drop it. If it is ever staged, note that its new tail
  `|> case do {:ok, statement} -> statement; statement -> statement end`
  swallows `{:error, changeset}` and hands the caller a tuple where every call
  site expects a struct — the `{:ok, statement} = …` match it replaces failed
  loudly, which is the better behaviour in a fixture.
* The spec-review suggestions log asked for a one-line pointer in the new test
  explaining why its dates are relative, next to the existing
  `dashboard_limit_test.exs` which uses 2025/2026 literals. The `setup` comment
  covers the "why" well; a bare mention of the sibling module would stop a future
  reader from "harmonising" the two in the wrong direction. Cosmetic.


## [CL-38] Pin the dashboard query count with a test, and explain it — 2026-10-11 (qa round 0)

- `test/support/fixtures/credit_cards_fixtures.ex` is modified in the working tree
  but **not staged**, and the modification is in the same area this task's fixture set
  uses (`statement_fixture/1` learning to derive `competencia` from `due_date` and to
  tolerate a non-`{:ok, _}` return). I checked whether CL-38 depends on it: with that
  file reverted to `HEAD`, the six new tests still pass (`6 tests, 0 failures`). So the
  commit boundary is safe as it stands. Worth a deliberate decision rather than an
  accident, though — either stage it with a reason or drop it, because a half-applied
  fixture change is a confusing thing to find later.
- The document's own Finding 5 is candid that the seven `>= 1` lower bounds cannot
  fail against today's controller, since every one of the seven tables is read
  unconditionally on the common path (it even reports verifying that deleting every
  `recurring_items` row leaves the count at 2). The assertions are still worth having —
  they catch an empty `by_table` with a rising `total`, which would make every ceiling
  vacuous at once — and ER2 asks for the assertions, which are present and two-sided.
  But the spec's `## Test criteria` bullet "Deleting the fixture rows that feed any one
  of the seven tables makes that table's `>= 1` assertion fail" is not true of the
  implementation, and the document says so rather than hiding it. No action needed for
  this task; flagged so that nobody later reads that bullet as a verified property.
- Minor arity/naming drift in the document's prose versus the code:
  `Forecast.upcoming_bills/1` and `/2`, `CreditCards.closed_without_statement/0` and
  `/2`, `Forecast.overdue_occurrences/0`, `/1` and `/2`,
  `Transactions.get_monthly_summary/0` and `/2` all appear in different places for what
  is presumably one function each. Harmless to a reader who knows the module, mildly
  confusing to one who does not.
- The `@total_ceiling` comment reads "282 measured + 20 = @total_delta", where the
  intent is "+ 20, which is `@total_delta`". The equation as punctuated says something
  else. One comma.


## [CL-39] Read each card's bill estimate once per card, not once per due-month — 2026-10-11 (spec review, CL-39-spec_review-0.md)

- Expected result 6 asserts two independent things in one line (`mix format --check-formatted` and the
  credo finding count). Both are mechanical, so it is not blocking, but splitting them would keep every
  result single-assertion as the rest of the list is.
- After this task `@total_delta` becomes 0, leaving `@total_ceiling` at 67 with no margin at all. The
  spec's argument for that is sound (every remaining group is already measured at delta 0 by CL-38), but
  a one-line comment in the test saying *why* the total now carries no margin — because the only two
  calendar-driven groups stopped being calendar-driven — would save the next reader from assuming the
  margin was dropped by accident.
- The spec's restatement of the estimate-sample query omits the `not is_nil(s.due_date)` guard that
  `estimate_for_month/2` actually carries. Harmless for the counts, but worth copying verbatim since the
  prefetch has to reproduce the same row set.
- Consider adding a regression test for the off-cycle `due_date` case described in the blocking finding
  (a statement in a walked month whose `due_date` precedes today). It is the one behaviour this
  refactor can silently change and no existing test covers it. Not required by the task's contract.

## [CL-39] Read each card's bill estimate once per card, not once per due-month — 2026-10-11 (spec review, CL-39-spec_review-1.md)
- Expected result 1 reads "reads each card's statements once for the whole
  horizon", which is now slightly out of step with the Approach section's
  insistence that the window is month-aligned and deliberately *not* the
  horizon. The result is about the *count* of reads, so it is still verifiable
  as written, but "once for the walked due-months" would stop a future reader
  from citing the result as licence for a `[today, horizon_end]` window. Worth
  a word change if the spec is edited again for another reason; not worth a
  round on its own.
- Since the window correctness is explicitly untestable against the current
  fixture set, consider noting in the spec that a fixture with an off-cycle
  `due_date` (one not derived from the card's `due_day`) would close that gap.
  Out of scope here — the spec forbids touching the budget test's fixtures so
  the ceilings stay comparable to CL-38 — so this is a candidate follow-up
  task, not a change to CL-39.

## [CL-39] Read each card bill estimate once per card — 2026-10-12
- Add a small forecast test for a month with two statements (same and different due_date) so the tie-break is pinned; the spec says the window/selection is review-only, and this bug shows why.

## [CL-43] Make mix precommit green again: compile warning, Credo strict, two date-dependent tests — 2026-10-12
- Result 1 and Result 5 each assert two things (compile and tests; precommit and test). Consider splitting them or simplifying them.
- "about 23 findings" is non-binding. Result 2 is the gate, so it is fine, but drop the count.
- The spec asks to "decide" the defect question in Scope, while Approach 4 already decides it. Align the wording.
- Result 4 in the spec's list omits the "no :estimado duplicate" wording that the Test criteria paragraph contains (since added to the task's expected results).

## [CL-49] Add users, authentication and enabled-user gate — 2026-10-12
- Approach, sign-up: state whether registration puts the user id in the session; the pending page is public yet is also where a logged-in disabled user lands. Pin the choice with one test assertion.
- Results 6 and 7 bundle several assertions; acceptable but near the one-assertion-per-line limit.
- Confirm a `citext` extension migration works on the test and CI Postgres.
- The `/api` 401 behavior and the LiveView `on_mount` hook have no expected result; consider adding one for the API.

## [CL-36] Anchor the BB CSV date and time extraction to the description prefix — 2026-10-12
- Result 5 ("existing tests and the new cases all pass") is a test-suite gate, not a behavior; acceptable but overlaps results 1-4.
- Result 6 is already true in the current code and is a regression guard only.
- State what happens when two standalone dd/mm tokens appear (presumably the first one is used).
- Clarify whether lowercase "parc" and "PARC." (with a dot) count as installment markers; the text says case-insensitive, so only the dot case is unclear.

## [CL-40] Answer the balance self-healing probe in one query, once per request — 2026-10-12
- Expected result 2 bundles three assertions (probe runs once, account list read once, latest balances read once); the spec pins them only indirectly through the budget ceilings. Consider splitting it, or adding a direct per-request query-count assertion for the account list and the latest balances.

## [CL-44] Make the month zebra striping stand out on the statements screen — 2026-10-12
- Expected result 1 says "the new stronger class" without naming it. The Approach names `bg-base-300/60` for option A. Naming it in the result would make QA's check exact.
- The DaisyUI `hover` row background is `base-200`. Against a `base-300/60` band it differs, but only slightly in the light theme. The mock shows this, so check it there.
- Results 3-5 (placeholder banding, mock visibility, hover distinct) are verifiable only in the mock or by eye. Say so in QA notes.

## [CL-45] Date a manual Rendimento entry from the account's last transaction — 2026-10-12
- Result 2 is largely implied by result 1; consider merging or keeping it only if it adds a distinct check (e.g. no-transaction running month).

## [CL-46] Aviso de fatura deve considerar o dia seguinte ao fechamento — 2026-10-12
- The Approach lists only the credit_cards_test changes. Add an explicit page_controller_test case for the dashboard warning on the closing day versus the next day, since expected result 3 depends on it.
- The "comparison is `:gt`" fix should be a `:lt` check: latest closing = this if this < today, else previous. The Approach already says this.

## [CL-47] Sincronizador deve inativar contas recorrentes que pararam de ser cobradas — 2026-10-12
- State that the "window" in the staleness check is the same 180-day `since` query used by suggest_for_category/1. The implementer may need to extract a shared rows query to avoid duplication.
- "Recent" for a single transaction is defined only by the cut-off (first of last month). A test fixture dated this month would make that unambiguous.

## [CL-48] Mostrar parcelamentos (financiamento, consórcio, empréstimo) na tela de Contas Recorrentes — 2026-10-12
- Spec says `Installments.parcel_position/2` returns 1 when not started; the helper may return nil in that case, so the implementation should clamp explicitly.
- `fully_grouped_category?/1` is private in forecast.ex; the sync_one change is in the same module, so this is fine.

## [CL-42] Resolve the excluded summary category ids once per request — 2026-10-12
- Result 4 is verified by "existing tests passing". An explicit test that calls the summaries with and without the option and compares results would be stronger.
- Result 3 says "creates a category under transfer (or re-parents one into it)". Pick one so the test is deterministic.

## [CL-49] Add users, authentication and enabled-user gate — 2026-10-13
- The staged diff also contains unrelated changes (forecast.ex logic rewrite, accounting.ex, credit_cards.ex, imports.ex, directory_importer, ingestor, transfer_matcher, mix tasks, forecast_test). Keep them out of the CL-49 commit.
- Login has no rate limiting (explicitly out of scope).

## [CL-36] Anchor the BB CSV date and time extraction to the description prefix — 2026-10-13
- csv_parser.ex infer_purchase_date/3: the spec says "if the result is later than the base date, use the previous year"; the implementation uses a 180-day future threshold (@max_future_days) to keep the legacy near-future behavior. Consider recording it in the spec.
- The anchoring helper uses Regex.scan with indexes and binary_part; slightly heavier than a single regex with lookbehind. Fine as is.

## [CL-50] Add user ownership schema and backfill existing data — 2026-10-13
- Approach says "ON DELETE RESTRICT (default :nothing semantics are fine)". These differ slightly in Postgres (NO ACTION can be deferred). Pick one, preferably `on_delete: :restrict`.
- Result 3 is verified only by the manual dump check or an optional migration test. Consider making the backfill test mandatory, or say that the manual report is the evidence.

## [CL-52] Application security review and hardening — 2026-10-13
- Result 5 bundles four headers into one line; tighten if QA finds it hard to judge.
- Results 3, 4, 5 and 9 lack a "(named test)" tag, though the Test criteria name a file for each.
- Result 10 depends on tool output; the PR gate covers it.

## [CL-54] Production readiness: account recovery, audit, health and privacy — 2026-10-13
- Results 1, 2 and 7 each bundle two or three checks in one sentence. They are still mechanically verifiable because the Test criteria section names each one, so this is not blocking. Splitting them would make QA reporting cleaner.
- The Sentry "may be swapped for an equivalent" clause is a soft spot. Consider fixing the vendor, since the DSN env and the test collector depend on it.
- State the trusted-proxy header config key explicitly, so the IP audit is implementable one way only.

## [CL-40] Answer the balance self-healing probe in one query, once per request — 2026-10-13
- Ceilings were tightened to 3 and 4 (spec required <=6 / <=5); fine, tests green.
- docs/tasks/CL-38-measurements.md D3 note (optional) not added.
- QA: credit_card_statement_live_test.exs:463 ("one-click reconciliation") failed once in mix precommit and then passed. It looks order-dependent, so consider a separate task.

## [CL-44] Make the month zebra striping stand out on the statements screen — 2026-10-13
- Code review: `hover:bg-primary/15` applies to all shaded rows including non-clickable placeholders; harmless.
- QA: unshaded rows have no hover effect (`hover` is a no-op in daisyUI 5; `row-hover` is the real class). Predates the task; consider `row-hover`.
- QA: priv/static CSS was not rebuilt; confirm `bg-base-300/60` and `hover:bg-primary/15` appear after the next asset build.

## [CL-45] Date a manual Rendimento entry from the account's last transaction — 2026-10-13
- Code review: a not-yet-started month keeps the month-end date. That goes beyond the spec and is reasonable, but no test covers it. Low risk.
- QA: `income_date/3` keeps month-end for a month not yet started; reasonable but undocumented in the spec.

## [CL-47] Sync must switch off recurring items whose bill stopped — 2026-10-13
- Code review: in the :insufficient_history branch the window query runs a second time (suggest_for_category already fetched the rows). Acceptable since the spec forbids changing the return contract.

## [CL-48] Mostrar parcelamentos (financiamento, consórcio, empréstimo) na tela de Contas Recorrentes — 2026-10-13
- Code review: list_commitment_rows calls Installments.last_installment_date twice per group; minor.

## [CL-42] Resolve the excluded summary category ids once per request — 2026-10-13
- Code review: the old `# Category ids to exclude...` comment now sits above the new `@doc`; move it next to `excluded_cash_summary_category_ids/0`.
- Code review: the freshness test does not assert the first request counted the transaction via ids resolved once; the budget test covers the query count, which is sufficient.

## [CL-50] Add user ownership schema and backfill existing data — 2026-10-13
- Code review: `CashLens.Ownership` plus the `Repo.insert/insert!` override and the process-dictionary pin go beyond the spec's "minimally pass a user through". Reasonable as a stopgap; remove it in CL-20 part 3, when the request supplies the user.
- Code review: `config :cash_lens, :auto_create_owner, true` in test config creates users implicitly; fixtures that take an explicit user would make tests clearer later.
- Code review: the migration interpolates the operator UUID into SQL (safe, it comes from `id::text`); a parameterized `execute` would be tidier.

## [CL-52] Application security review and hardening — 2026-10-13
- Code review: `rate_limit.ex` `client_ip/2` with `trust_proxy_headers` takes the last `x-forwarded-for` entry, correct for a single trusted proxy; document that it is wrong for a multi-hop chain.
- Code review: `validate_drop/2` reads the whole file (up to 10 MB) after stat; fine at this size. The control-byte list is rebuilt per call and could be a module attribute.
- Code review: keep the global `Config.Headers` sobelow ignore under review, since it would also hide a real missing-headers regression on other pipelines.

## [CL-54] Production readiness: account recovery, audit, health and privacy — 2026-10-13
- Code review: `mix.exs` adds `hackney` only for `Sentry.HackneyClient`; it is a second HTTP client alongside Req.
- Code review: `runtime.exs` now raises at boot in prod if `MAILGUN_API_KEY` or `MAILGUN_DOMAIN` is missing; update the deploy env first.

## [CL-50] Add user ownership schema and backfill existing data — 2026-10-13
- Code review: `Repo.insert/insert!` is overridden globally to auto-assign the operator, with a test-only `:auto_create_owner` branch; this goes past "minimally pass a user through" and hides missing owners in later CL-20 parts. Prefer explicit `user_id` in fixtures and the ingestor. The `insert/3` arities are not covered by the override.
- Code review: `Ownership.operator_user_id!/0` compares email with `==`; the spec requires a case-insensitive match (citext). Add a test for it.
- Code review: the migration interpolates the operator id into SQL; use a parameterized `repo().query!`.
- Code review: Privacy `@owned` now covers all domain schemas, so export and delete reach financial data. Confirm this is intended, since the spec does not list it.

## [CL-51] Scope all queries by the current user — 2026-10-13
- Spec review: the guard regex works on text blocks, so a query written without Repo.* in the same function block could slip through. Acceptable as a heuristic.
- Spec review: Expected Result 1 says "enforced by user_scoping_audit_test.exs", but that test only checks scoping inside blocks, not the first-argument convention. Consider rewording later.

## [CL-53] Database security review and hardening — 2026-10-13
- Spec review: Result 4 bundles four assertions; Test criteria cover encryption, no plaintext and abort but not retention pruning. Add a pruning check with fake-dated files so QA can verify 7/4/6 mechanically.
- Spec review: Result 5 and the RLS table list depend on CL-50's migration existing; keep CL-50 in `blockedBy`.
- Spec review: Result 1 "exits 0 only when" is best verified with a negative case (running the task against the owner role must exit non-zero); mention it in the role test.
- Spec review: running the suite as a non-owner role means migrations and test DB setup must run as owner; keep the `mix test` alias explicit about that.
- Code review: `Repo` overrides a long list of functions to wrap them in a transaction; `query/3` and `stream/2` are not wrapped (documented). Consider a lint or test guarding new direct raw-SQL callers.
- QA: Install age in CI so the real-age round-trip test is not skipped.
- QA: The transaction_live "saves new transaction" test flaked once in the full run; watch for recurrence.

## [CL-55] Add ownership scoping foundation and tenancy test helpers — 2026-10-13
- Spec review: `operator_user!/0` duplicates the private `operator_user_id!/0`; state whether it reuses it (minus the auto-create fallback) so the two do not drift.
- Spec review: `validate_owned/3` should state which error key/validation tag it uses so tests can assert it via `errors_on/1`.
- Spec review: scope text says "account, balance, category, ..." fixtures while results say "accounts, accounting, ..." files; align names to file names.

## [CL-56] Scope Accounts and Categories by the current user — 2026-10-13
- Spec review: `keyword_conflicts` signature is left open (`keyword_conflicts(user, categories)`-style or required list); pick one shape.

## [CL-57] Scope Accounting and balance recalculation by the current user — 2026-10-13
- Spec review: `Repo.with_user/2` takes a `user_id` (lib/cash_lens/repo.ex:74), while the spec says it pins the loaded user; state that it is passed `user.id`.
- Spec review: Oban uniqueness is `period: 60` with default keys, so it covers all args; the spec already says to verify this.
- Spec review: `Ownership.scope/2` and `cross_tenant` come from CL-55; make sure `blockedBy` includes CL-55 as well as CL-56.

## [CL-58] Scope Transactions core by the current user — 2026-10-13
- Spec review: result 1 covers several modules (signatures and scoping) in one line; it is checkable through the tenancy tests, but could be split.
- Spec review: result 3 lists four entity families; fine as one result since the test file is the single verification artifact.

## [CL-59] Scope Installments and CreditCards by the current user — 2026-10-13
- Spec review: confirm `blockedBy` includes CL-55, CL-56, CL-57 and CL-58 (`Ownership.scope/2` is not yet in `ownership.ex`; it comes from CL-55).
- Spec review: result 3 names only `payment_transaction_id`/`installment_group_id`/`account_id`; the spec also covers `absorbed_by_statement_id` and `parent_id`, which could be added to the tests.
- Spec review: the "(or return nil as they do today)" wording for `get_statement_detail` leaves two behaviours; the implementer should keep the existing one.

## [CL-60] Scope Forecast and recurring items by the current user — 2026-10-13
- Spec review: the worker calls `Ownership.pin_operator!()` (RLS, CL-53); say whether it stays and how the user lookup runs under it.
- Spec review: "flash broadcast addressed to that user only" requires changing `CashLensWeb.RecurringSyncFlash` (topic per user and subscribers); add it to Files touched and the test criteria.
- Spec review: state where the user goes relative to defaulted args (`today`, `opts`) in functions such as `Forecast.project/3`.

## [CL-61] Scope imports and tooling by user, then remove the owner fallback — 2026-10-13
- Spec review: the audit regex requires `user_id` or `Ownership.scope(` in the block; a block that only mentions `user_id` in a comment would pass, so say whether comments are stripped.
- Spec review: confirm `Repo.with_user/2` and `Repo.put_current_user_id/1` exist today, since the spec says they "stay".
- Spec review: Part B is large (five-step lockdown plus the audit test) on top of Part A; consider an explicit ordering note (Part A green first).
- Spec review: the expected results do not directly cover seeds, `ImportLive` scoping, the lockdown deletions (`Ownership.assign/1`, `:auto_create_owner`) or the AGENTS.md update; Test criteria covers them, and result 7 could name the `:auto_create_owner` removal if a slot frees up.

## [CL-55] Add ownership scoping foundation and tenancy test helpers — 2026-10-13
- Code review: `Tenancy.pop_user` treats `user: nil` like an absent key; acceptable, but worth a doc line.

## [CL-56] Scope Accounts and Categories by the current user — 2026-10-13
- Code review: `Categories.broadcast/2` hand-builds the topic string instead of reusing `topic/1`. Minor DRY.
- Code review: `AccountLive.Index` uses `fetch_account` (rescue) while `Show` has its own `assign_account`. Acceptable.
- QA: Fix the compile warning at test/cash_lens/categories_test.exs:241.
