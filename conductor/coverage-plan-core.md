# Implementation Plan: 100% Test Coverage for Core (lib/cash_lens/)

## Objective
Reach 100% test coverage for all modules within the `lib/cash_lens/` directory. The current overall coverage is good, but there are missing edge cases and error handling paths in several core files.

## Key Files & Context
- `lib/cash_lens/accounting.ex` (92.8%)
- `lib/cash_lens/accounts.ex` (87.5%)
- `lib/cash_lens/categories/category.ex` (Current coverage missing fallbacks)
- `lib/cash_lens/transactions.ex` (98.2%)
- `lib/cash_lens/transactions/auto_categorizer.ex` (95.8%)
- `lib/cash_lens/workers/recalculate_balance_worker.ex` (77.7%)
- `lib/cash_lens/parsers/*` (Ingestor, CSV, OFX, PDF - ~78% to 90%)

## Implementation Steps
1. **Accounts & Categories (Quick Wins):**
   - Update `test/cash_lens/accounts_test.exs` to cover `get_total_balance` when no accounts exist, and `get_account_by_name`.
   - Update `test/cash_lens/categories_test.exs` to cover `full_name/1` when `parent` is nil or not loaded.
2. **Transactions & Worker:**
   - Update `test/cash_lens/transactions_test.exs` and `auto_categorizer_test.exs` for missing edge cases.
   - Update `test/cash_lens/workers/recalculate_balance_worker_test.exs` to cover invalid arguments and enqueue failures.
3. **Accounting Context:**
   - Update `test/cash_lens/accounting_test.exs` to cover `handle_initial_balance_fallback`, `calculate_from_point` failure cases, and `list_balances` with empty string filters.
4. **Parsers (Ingestion):**
   - Update `test/cash_lens/parsers/csv_parser_test.exs`, `ofx_parser_test.exs`, `pdf_parser_test.exs`, and `ingestor_test.exs`.
   - Add tests for invalid date/time/amount formats, unsupported extensions, and empty files.

## Verification & Testing
- Run `mix test --cover` to verify that all files within `lib/cash_lens/` report 100% coverage.
- Ensure all tests pass without failures.