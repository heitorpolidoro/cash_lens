
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
