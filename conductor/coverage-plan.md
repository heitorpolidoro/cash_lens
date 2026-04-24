# Implementation Plan: 100% Test Coverage

## Objective
Reach 100% test coverage for the CashLens project by adding unit and LiveView tests to the remaining uncovered modules, as identified by the coverage report.

## Key Files & Context
- `lib/cash_lens_web/live/transaction_live/index.ex`
- `lib/cash_lens_web/live/admin_database_live.ex`
- `lib/cash_lens_web/live/transaction_live/transfer_link_component.ex`
- `lib/cash_lens_web/live/transaction_live/reimbursement_link_component.ex`
- `lib/cash_lens_web/live/automation_live/bulk_ignore_pattern_live.ex`
- `lib/cash_lens/workers/recalculate_balance_worker.ex`
- `lib/cash_lens/parsers/ingestor.ex`

## Implementation Steps
1. **RecalculateBalanceWorkerTest:** Create `test/cash_lens/workers/recalculate_balance_worker_test.exs` with logic to test enqueuing the next month's balance.
2. **IngestorTest:** Enhance `test/cash_lens/parsers/ingestor_test.exs` to test `import_file/2` with CSV parsing and handling invalid files.
3. **AdminDatabaseLiveTest:** Create `test/cash_lens_web/live/admin_database_live_test.exs` to test rendering database tables and filtering.
4. **BulkIgnoreTest:** Create `test/cash_lens_web/live/automation_live/bulk_ignore_test.exs` to test creating and deleting patterns.
5. **TransactionLiveTest:** Create/update `test/cash_lens_web/live/transaction_live_test.exs` to include tests for sorting, filtering by unmatched/credit, and the complex logic in `TransferLinkComponent` and `ReimbursementLinkComponent` (including modals and batch actions).

## Verification & Testing
- Run `MIX_ENV=test mix coveralls` and verify the total coverage reaches 100% (or identifies any small edge cases missed).
- Open a PR with the new tests.