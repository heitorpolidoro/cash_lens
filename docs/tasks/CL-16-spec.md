# CL-16 — Redesign the Categories screen (/categories) with a hierarchical tree and keyword management

## Scope
Modernize the Categories management screen (`/categories`), replacing the flat table with a hierarchical tree view (root categories with collapsible subcategories). The interface highlights the Fixed Cost (essential/survival) versus Variable Expense (lifestyle) classification, surfaces the auto-categorization keyword rules, and unifies create/edit into a single dynamic modal with a simplified parent-category selector and keyword input.

Includes:
- Collapsible hierarchical tree:
  - Root categories rendered as master cards with a representative icon/emoji.
  - Subcategories nested and indented inside each master card.
  - "Expandir Todos" / "Recolher Todos" quick actions.
  - Action on the parent card to add a direct subcategory with the parent pre-selected (`+ Subcategoria`).
- Filter bar with real-time search:
  - Quick type tabs, labelled exactly `Todas`, `Custos Fixos`, `Variáveis` and `Reembolsáveis`. The tabs carry labels only: they must NOT display any count or quantity next to the label.
  - Search field matching category name or registered keywords.
- Keyword rule visualization:
  - Chips/tags for the terms associated with each category (e.g. `uber`, `ifood`, `enel`).
  - Quick Fixed/Variable type toggle without opening the full edit form, carrying an inline hint explaining what "Fixo" does.
- Unified category/subcategory modal:
  - Replaces the full-page `/categories/new` and `/categories/:id/edit` screens with a responsive LiveView modal.
  - Fields: category name, parent category (optional select), type (Fixed or Variable), a single plain "Reembolsável por Padrão?" checkbox (label only, no secondary sub-label), and a comma-separated keywords textarea.
- Deletion of categories and subcategories, preserved from the current screen (see Approach §1).
- Icon-only Edit/Delete actions with accessible names on root cards and subcategory rows (see Approach §1).
- Update and extend tests in `test/cash_lens_web/live/category_live_test.exs`.

Explicitly out of scope:
- Changes to the `CashLens.Categories.Category` schema or new migrations (`parent_id`, `slug`, `type`, `keywords` and `default_reimbursable` already exist).
- Changes to the automatic categorization algorithm (`AutoCategorizer`).
- Summary/metric count cards at the top of the screen — the screen must NOT display aggregate counters for roots, fixed costs, variable expenses or keyword rules.

## Approach
### 1. Behavior
- `/categories` is still served by `CashLensWeb.CategoryLive.Index`.
- On mount, categories are loaded and organized into a tree by grouping `parent_id == nil` roots with their children.
- Expand/collapse of groups is server-side LiveView state: a `@collapsed_groups` assign (a MapSet of root category ids) toggled by a `toggle_group` event. `JS.toggle` is not used, so that the collapsed state survives re-renders caused by filtering, searching and saving.
- The page renders the page title, the expand/collapse actions, the filter/search bar and the tree — no metric cards between the header and the filter bar.
- The create/edit modal opens via `patch(~p"/categories/new")` or `patch(~p"/categories/#{category.id}/edit")`, using `FormComponent` or a dedicated modal.
- In the modal, "Reembolsável por Padrão?" is a single checkbox whose only visible text is that label; there is no additional descriptive text next to the input.
- Deletion stays in scope: every root card and every subcategory row exposes an "Excluir" affordance next to its "Editar" affordance, firing the `confirm_delete` event, which opens the "Excluir Categoria?" confirm modal.
- **Icon-only actions.** On both root cards and subcategory rows, the edit and delete affordances render as icon-only controls, with no visible text label: a pencil (`<.icon name="hero-pencil" />`) for edit and a bin (`<.icon name="hero-trash" />`) for delete. They follow the existing convention of `lib/cash_lens_web/live/account_live/index.ex` (`card_actions/1`): ghost icon buttons, the delete one tinted with the error colour, each carrying **both** a `title` and an `aria-label` with its accessible name. Names are exactly `Editar categoria` / `Excluir categoria` on root cards and `Editar subcategoria` / `Excluir subcategoria` on subcategory rows. The "+ Subcategoria" action and the confirm modal's "Excluir" button keep their visible text and are unaffected.
- **Fixo hint.** "Fixo" is not a boolean flag but `Category.type`, either `"fixed"` or `"variable"` (default `"variable"`), labelled `Fixo (Contas Essenciais)` elsewhere in the app (`category_live/form.ex:99`, `quick_category_component.ex:104`). Its one behavioural consequence is at `lib/cash_lens/forecast.ex:84`, where only `type == "fixed"` categories (excluding credit-card ones) are collected by the cash forecast at `/forecast` as recurring commitments; it also colours the month panel (blue for fixed, amber for variable, `month_live/month_panel.ex:442`). Because that meaning is not discoverable from the label, the screen must state it inline, in Portuguese, using this exact copy: `Fixo (Contas Essenciais): entra na previsão de caixa em /forecast como compromisso recorrente.` It appears twice: as the `title` tooltip of every quick Fixo toggle on the tree, and as a one-line caption under the "Tipo de Gasto" select in the create/edit modal. No behavioural change to forecasting is in scope — only the hint.
- The `confirm_delete` handler in `lib/cash_lens_web/live/category_live/index.ex` is **extended, not reused as-is**: besides opening the modal, it determines whether the target category has children (pre-check, before any delete is attempted) and passes the category name plus that boolean into the modal assigns. The modal body and the state of its confirm button are derived from those assigns.
- Category **without** children: the modal body reads exactly `Esta ação não pode ser desfeita. Excluir "<name>" permanentemente?` (with `<name>` being the category name), and the "Excluir" confirm button is **enabled**. Confirming fires the existing `delete` event handler, unchanged, which removes the category.
- Root category **with** children: the modal body reads exactly `A categoria "<name>" possui subcategorias. Reatribua ou exclua as subcategorias antes de excluir esta categoria.` and the "Excluir" confirm button is **disabled** (rendered with the `disabled` attribute). No `delete` event is ever dispatched, no deletion is attempted, and no flash message is involved in this path.
- The existing `Ecto.Changeset.no_assoc_constraint(:children)` in `lib/cash_lens/categories.ex` stays untouched as the server-side backstop for deletes that bypass the UI pre-check; the pre-check is an additional guard, not the only protection.
- The `Reembolsável por Padrão` badge on a root card and the `Marca Reembolso` badge on a subcategory row (see mock) are intentional: they render when `default_reimbursable` is true, and are the only reimbursable indicators on the tree.

### 2. Files Touched
- `lib/cash_lens_web/live/category_live/index.ex`: render the root-card and subcategory-row edit/delete actions as icon-only buttons with `title` + `aria-label`, and add the Fixo hint as the `title` of the quick type toggle. Restructure the HEEx render, replacing the flat table with the hierarchical tree, count-free filter tabs and search; no summary cards. The delete affordance is re-placed on root cards and subcategory rows. The `confirm_delete` handler is extended to compute the target category's name and whether it has children, and to store them in the modal assigns; the "Excluir Categoria?" confirm modal markup becomes dynamic (two body texts, confirm button enabled or `disabled`). The `delete` handler is unchanged.
- `lib/cash_lens_web/live/category_live/form_component.ex`: update the form to work as a modern modal with parent selection, keyword tags and the single-label reimbursable checkbox; add the Fixo hint caption under the type select.
- `lib/cash_lens/categories.ex`: add `group_by_parent/1`, which takes the loaded category list and returns the hierarchical structure `[{root_category, [child_category]}]` consumed by the tree render. `delete_category/1` and its `no_assoc_constraint(:children)` are unchanged.
- `test/cash_lens_web/live/category_live_test.exs`: update and expand tests covering tree rendering, subcategory creation and type filters.

### 3. Test Criteria
- `test/cash_lens_web/live/category_live_test.exs` asserts:
  - The tree renders roots with nested subcategories.
  - Type filters labelled `Todas`, `Custos Fixos`, `Variáveis`, `Reembolsáveis` work, and none of the four tab labels contains a digit.
  - A new subcategory is created with the associated parent through the modal.
  - Quick toggle between `fixed` and `variable`.
  - The rendered index contains no visible `Editar`/`Excluir` text on root cards or subcategory rows, while exposing `aria-label` values `Editar categoria`, `Excluir categoria`, `Editar subcategoria` and `Excluir subcategoria`, and the delete action reached through the icon still opens the "Excluir Categoria?" confirm modal.
  - The rendered index and the create/edit modal both contain the literal hint string `Fixo (Contas Essenciais): entra na previsão de caixa em /forecast como compromisso recorrente.`
  - The rendered index contains no summary/metric counter cards.
  - `confirm_delete` on a leaf category renders the modal body containing the literal string `Esta ação não pode ser desfeita. Excluir "<name>" permanentemente?` with an enabled confirm button, and firing `delete` afterwards removes it from the rendered list.
  - `confirm_delete` on a root category that still has children renders the modal body containing the literal string `A categoria "<name>" possui subcategorias. Reatribua ou exclua as subcategorias antes de excluir esta categoria.`, the confirm button carries the `disabled` attribute, and the category is still present in the database and in the rendered tree (no flash message is asserted, because no delete is attempted).
- `mix test test/cash_lens_web/live/category_live_test.exs` passes 100%.
- `mix quality_check` passes with 0 errors and 0 warnings.

## Expected Results
- [ ] Hierarchical tree view of root categories with collapsible subcategories
- [ ] Quick type filter with the labels Todas, Custos Fixos, Variáveis, Reembolsáveis, none of them showing a count, plus dynamic search
- [ ] Create/edit modal supporting hierarchical categorization and keywords
- [ ] Shortcut on the parent card to create a subcategory with the parent pre-selected
- [ ] The "Reembolsável por Padrão?" control is a single checkbox with that label and no secondary sub-label
- [ ] The screen shows no metric/count summary cards
- [ ] Every root card and every subcategory row offers an Excluir action that opens the "Excluir Categoria?" confirm modal; confirming deletes a leaf category
- [ ] Opening the confirm modal for a root category that still has subcategories shows the reassign-or-delete-first warning in the modal body and a disabled confirm button, so no delete is attempted
- [ ] Edit and delete on root cards and subcategory rows are icon-only (pencil and bin) with no visible text label, each exposing an accessible name via `title` and `aria-label` (`Editar categoria` / `Excluir categoria` / `Editar subcategoria` / `Excluir subcategoria`), and still trigger the edit modal and the delete confirm modal
- [ ] The quick Fixo toggle and the modal type field show the inline hint `Fixo (Contas Essenciais): entra na previsão de caixa em /forecast como compromisso recorrente.`
- [ ] Test suite passes with `mix quality_check`

## Out of Scope
- Database schema changes or migrations.
- Changes to the auto-categorization engine.
- Aggregate metric cards on the categories screen.
