# Implementation Plan: Translation to English

## Objective
Convert all user-facing text, internal messages, and documentation from Portuguese to English. This is a "hardcoded" translation phase, postponing full internationalization (i18n) for later.

## Key Files & Context

### Web Layer (UI/UX)
- `lib/cash_lens_web/components/core_components.ex`: Translate "Ações", "close", etc.
- `lib/cash_lens_web/live/account_live/*`: Titles ("Contas"), buttons, flash messages.
- `lib/cash_lens_web/live/admin_database_live.ex`: Table administration labels.
- `lib/cash_lens_web/live/automation_live/bulk_ignore.ex`: "Regras de Exclusão", "Motivo", etc.
- `lib/cash_lens_web/live/balance_live/*`: "Balanços", "Mês", "Saídas", etc.
- `lib/cash_lens_web/live/category_live/*`: "Categorias", "Palavras-chave", etc.
- `lib/cash_lens_web/live/transaction_live/*`:
    - `index.ex`: Translate `translate_month/1`, flash messages ("Sucesso!"), and labels.
    - `index.html.heex`: (If any hardcoded text exists).
    - Components: `import_modal_component.ex`, `quick_category_component.ex`, etc.

### Core Layer (Logic & Data)
- `lib/cash_lens/parsers/ingestor.ex`: Error messages ("Extrator não configurado").
- `lib/cash_lens/parsers/pdf_parser.ex`: Regex patterns (e.g., `às` to `at` or supporting both).
- `lib/cash_lens/transactions/auto_categorizer.ex`: Bank-specific description matches.
- `lib/cash_lens/transactions/bulk_ignore_pattern.ex`: Validation errors ("Regex inválida").
- `lib/cash_lens/accounting.ex`: Logging and internal messages.

### Documentation
- `BACKLOG.md`: Translate the entire strategy and backlog.

## Implementation Steps

### Phase 1: Foundation & Components
1. Translate `CoreComponents`.
2. Update global navigation and layout if necessary (check `lib/cash_lens_web/components/layouts.ex`).

### Phase 2: LiveView Translation
1. Batch translate LiveViews by context (Accounts -> Categories -> Transactions -> Balances).
2. Ensure `translate_month/1` in `TransactionLive.Index` returns English month names.

### Phase 3: Core Logic & Parsers
1. Translate error strings returned by Context modules.
2. Update parsers to ensure they still work with bank statements (which might still be in Portuguese) but report errors in English.

### Phase 4: Documentation
1. Translate `BACKLOG.md`.

### Phase 5: Verification
1. Run `mix test` and update any tests that assert on Portuguese strings.
2. Perform a manual walkthrough of the application.

## Verification & Testing
- **Automated Tests**: `mix test` must pass.
- **Manual Check**: Verify all flash messages, modal titles, and table headers are in English.
- **Data Integrity**: Ensure slugs (like "rendimentos") are handled or migrated if they affect logic (e.g., `get_category_by_slug("rendimentos")`).
