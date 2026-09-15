
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
