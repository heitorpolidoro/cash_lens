# CL-15 — Redesign the Accounts screen (/accounts) with a bank-card visual and a configuration modal

## Scope
Modernize the Accounts and Cards management screen (`/accounts`), replacing the current raw table with a visual interface inspired by bank cards and digital wallets. The screen clearly separates checking accounts / digital wallets from credit cards, shows a live total of bank balances, surfaces key operational information (statement closing and due days, configured parser), supports showing/hiding closed accounts, and unifies creation and editing in a responsive LiveView modal with an institutional color picker.

Includes:
- 2 clearly differentiated main sections:
  - Bank Accounts and Digital Wallets:
    - Consolidated Total Balance indicator in the section header.
    - Styled bank card with avatar/initials, institutional color (`account.color`), bank, current balance highlighted, and initial balance.
    - Direct shortcut to the account statement (`/transactions?account_id=...`).
    - Quick actions: edit settings, archive/close, or reactivate.
  - Credit Cards:
    - Visual card with chip, brand, and theme color.
    - Cycle metadata: closing day (`closing_day`) and due day (`due_day`).
    - Associated statement parser/extractor (OFX, PDF, CSV, Ourocard TXT).
    - Direct shortcut to the card statements (`/statements?account_id=...`).
- Unified New Account / Edit Account modal:
  - Replaces the full-page routes (`/accounts/new`, `/accounts/:id/edit`) with a LiveView modal rendered over the screen itself (still supporting direct routes via `live_action: :new` and `:edit`).
  - Fields: account name, bank/institution, initial balance, theme color picker (presets for the main institutions such as Nubank, Itaú, BB, Mercado Pago, Inter, etc.), credit-card toggle that conditionally reveals closing and due day, **parser/extractor selector**, **account icon**, and the "accepts import" toggle.
  - **Parser selector (`parser_type`)**: a `select` with prompt "Selecione um extrator" and exactly the option set already used by `AccountLive.Form` — `bradesco_csv`, `bradesco_cartao_pdf`, `mercadopago_cartao_pdf`, `bb_csv`, `mercado_pago_csv`, `ourocard_ofx`, `sem_parar_pdf`, `standard_ofx` — with labels identical to `Formatters.translate_parser_type/1`. This task introduces no new parser options and does not change the parser list.
  - **Icon field (`icon`)**: an optional URL text input paired with a circular live preview that renders `<img src={icon}>` when filled and a placeholder icon (`hero-photo`) when empty — the same behavior the current form already has. The `icon` field is a plain string URL in the schema; no binary file upload is introduced.
- Closed accounts filter:
  - "Mostrar contas encerradas" checkbox/toggle, with a subtle badge and reduced opacity for deactivated accounts.
- Update the test suite in `test/cash_lens_web/live/account_live_test.exs`.

Explicitly out of scope:
- Changes to the `CashLens.Accounts.Account` schema or database migrations (all fields already exist in the schema).
- Automated Pluggy bank connection management (already isolated under `/pluggy`).

## Approach
### 1. Behavior
- `/accounts` is still served by `CashLensWeb.AccountLive.Index`.
- On mount, the LiveView loads all the user's active accounts, and also accounts with `is_closed: true` when the filter is enabled.
- The LiveView splits accounts into two reactive assigns: `@bank_accounts` (`is_credit_card: false`) and `@credit_cards` (`is_credit_card: true`).
- The create/edit modal keeps the URL in sync through `patch(~p"/accounts/new")` and `patch(~p"/accounts/#{account.id}/edit")`.
- Archiving/closing toggles `is_closed` via `Accounts.update_account(account, %{is_closed: !account.is_closed})` with immediate feedback.
- The modal form submits `parser_type` and `icon` together with the remaining account params, so saving an existing account preserves or updates both values; the icon preview reacts to the existing `phx-change="validate"` cycle without an extra event.

### 2. Files Touched
- `lib/cash_lens_web/live/account_live/index.ex`: restructures the HEEx render, replacing the table with the bank-card sections and the archived-accounts filter control.
- `lib/cash_lens_web/live/account_live/form.ex` (or the extracted form component used by the modal): modernizes the form into the modal layout with the institutional color picker, conditional credit-card fields, the parser `select`, and the icon URL field with preview.
- `lib/cash_lens/accounts.ex`: helper functions for the segregated listing and the active total balance calculation where convenient.
- `test/cash_lens_web/live/account_live_test.exs`: adjusts existing tests and adds assertions for the card visuals, the total, and the edit modal (including parser and icon).

### 3. Test Criteria
- `test/cash_lens_web/live/account_live_test.exs` verifies:
  - Bank accounts and credit cards are listed in separate sections.
  - The bank accounts total balance is rendered correctly.
  - The new-account and edit modals open and submit successfully.
  - The edit modal renders the `parser_type` select with the current value preselected and the `icon` URL input populated from the account.
  - Submitting the edit modal with a changed `parser_type` and `icon` persists both values.
  - Toggling visibility and archiving of closed accounts.
- `mix test test/cash_lens_web/live/account_live_test.exs` passes at 100%.
- `mix quality_check` passes with 0 errors and 0 warnings.

## Expected Results
- [ ] Visual interface with distinct bank account cards and credit card cards instead of a plain table
- [ ] Consolidated available balance total displayed at the top of the bank accounts section
- [ ] Card rules clearly shown (closing day, due day, configured parser)
- [ ] Integrated create/edit modal with institutional color picker
- [ ] The edit modal includes a parser/extractor `select` listing the eight existing parser options with the account's current `parser_type` preselected, and saving persists the chosen value
- [ ] The edit modal includes an optional account icon URL field with a live circular preview (placeholder when empty), and saving persists the `icon` value
- [ ] Support for toggling display and archiving of closed accounts
- [ ] `mix quality_check` passes with the full test suite green

## Out of Scope
- Database migrations.
- Open Finance (Pluggy) credential management.
- Binary file upload for the account icon (`icon` remains a URL string) and any change to the available parser option list.
