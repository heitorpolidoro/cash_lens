# Implementation Plan: 100% Global Test Coverage

## Objective
Achieve 100% global test coverage for the entire CashLens project (currently at 86.6%). This requires closing the remaining minor gaps in the Core (`lib/cash_lens/`) and systematically adding test coverage to the Web Layer (`lib/cash_lens_web/`), focusing heavily on LiveViews and Components.

## Key Files & Context

### 1. Remaining Core Gaps (~1-5% per file)
- `lib/cash_lens/accounting.ex` (95.2%)
- `lib/cash_lens/parsers/*` (CSV: 96.9%, Ingestor: 96.0%, OFX: 97.2%)
- `lib/cash_lens/transactions.ex` (97.3%)
- `lib/cash_lens/transactions/transfer_matcher.ex` (92.1%)
- `lib/cash_lens/transactions/auto_categorizer.ex` (95.8%)
- `lib/cash_lens/transactions/transaction.ex` (94.1%)

### 2. High Priority Web Components (Lowest Coverage)
- `lib/cash_lens_web/live/transaction_live/import_modal_component.ex` (27.0%)
- `lib/cash_lens_web/components/layouts.ex` (44.4%)
- `lib/cash_lens_web/live/transaction_live/reimbursement_link_component.ex` (56.2%)
- `lib/cash_lens_web/live/transaction_live/transfer_link_component.ex` (72.8%)

### 3. Main LiveViews (~75-90% Coverage)
- `lib/cash_lens_web/live/category_live/*` (Index: 75.6%, Form: 87.0%)
- `lib/cash_lens_web/live/reimbursement_live/*` (Index: 80.6%)
- `lib/cash_lens_web/live/transaction_live/index.ex` (82.8%)
- `lib/cash_lens_web/live/balance_live/*` (Index: 82.6%, Form: 87.2%)
- `lib/cash_lens_web/live/account_live/*` (Index: 90.9%, Form: 95.0%)

### 4. Core Web Utilities
- `lib/cash_lens_web/components/core_components.ex` (81.8%)
- `lib/cash_lens_web/controllers/page_controller.ex` (86.6%)
- `lib/cash_lens_web/telemetry.ex` (75.0%)

## Phased Implementation Steps

### Phase 1: Core Mop-up
1.  **Transactions & Matchers:** Analyze `mix coveralls.json` for the last missed lines in `Transactions` context, `TransferMatcher`, and `AutoCategorizer`. Add the missing edge cases (e.g., error paths, default arguments) to their respective tests.
2.  **Accounting & Parsers:** Cover the 4 missed lines in `accounting.ex` and the remaining 4 lines spread across `csv_parser.ex`, `ingestor.ex`, and `ofx_parser.ex`.

### Phase 2: LiveView Components
1.  **ImportModalComponent:** Create/update tests to fully cover file uploads, valid/invalid MIME types, and the parsing response flow (currently at 27%).
2.  **Link Components:** Cover the complex modal logic, unlinking, and selection edge cases in `reimbursement_link_component.ex` and `transfer_link_component.ex`.

### Phase 3: Main LiveViews
1.  **Reimbursements & Categories:** Expand `reimbursement_live_test.exs` and `category_live_test.exs` to hit all event handlers (sorting, filtering, pagination if any, and deletion confirmation flows).
2.  **Transactions & Balances:** Add missing interaction paths in `transaction_live/index_coverage_test.exs` and `balance_live_test.exs` (e.g., adjusting specific balances, triggering worker recalculations).
3.  **Accounts:** Finish the remaining 5% covering form errors and index interactions.

### Phase 4: Core Web & Layouts
1.  **CoreComponents:** Write a dedicated `core_components_test.exs` to render and assert behaviors of complex UI components (modals, flash messages, custom inputs).
2.  **Layouts & Telemetry:** Ensure `layouts.ex` error cases and `telemetry.ex` standard events are covered in `page_controller_test.exs` or standalone tests.

## Verification & Testing
- Use `MIX_ENV=test mix coveralls.html` iteratively to visualize exact missing lines.
- Run `MIX_ENV=test mix coveralls` and verify the total project coverage reaches exactly 100.0%.
- Ensure 0 warnings and 0 failures throughout the process.
