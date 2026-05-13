# Installments & 6-Month Projection Plan

## Objective
Implement an Installment Group ("Contas Parceladas") system that tracks long-term purchases without polluting current balances with unverified future transactions. Enhance the main dashboard chart with a 6-month future projection based on historical averages and pending installments.

## Scope & Impact
*   **Installment Groups**: A new entity to track the total debt, number of installments, and description pattern.
*   **Transactions**: Will gain an `installment_group_id` and `installment_number` to link real bank imports to the planned debt.
*   **Auto-Linking**: The ingestor/categorizer will suggest linking new transactions to active installment groups based on description matching.
*   **Dashboard**: The balance chart will project 6 months into the future, using a 12-month average for income/expenses, plus the expected virtual installments. Highlighted with a vertical line and background split.

## Proposed Solution

### Phase 1: Database Schema Updates
1.  **Create `installment_groups` table**:
    *   `description_pattern` (string) - for matching imports.
    *   `total_amount` (decimal).
    *   `installments` (integer).
    *   `start_date` (date).
2.  **Modify `transactions` table**:
    *   Add `installment_group_id` (UUID, optional) to link the real transaction to the group.
    *   Add `installment_number` (integer, optional).

### Phase 2: Backend Logic & Contexts
1.  **Installments Context (`CashLens.Installments`)**:
    *   CRUD for `InstallmentGroup`.
    *   Logic to calculate the "progress" of a group (e.g., 3 out of 12 paid).
2.  **Transaction Context (`CashLens.Transactions`)**:
    *   **Auto-Suggest**: Update the categorization engine. When a transaction is imported, if its description matches an active `InstallmentGroup`'s pattern, suggest linking it and calculate the next expected `installment_number`.

### Phase 3: UI Updates (Forms & Lists)
1.  **Installments Management**:
    *   A new page or modal to manage active Installment Groups.
2.  **Transaction Form & List (`TransactionLive`)**:
    *   Add a dropdown/search to manually link a transaction to an existing `InstallmentGroup`.
    *   Display a badge (e.g., "3/12") on linked transactions in the list.
    *   When the system suggests a link during bulk import, show it in the confirmation modal.

### Phase 4: Dashboard & Projections
1.  **PageController (`CashLensWeb.PageController`)**:
    *   Calculate the average `income` and `expenses` from the 12-month historical data.
    *   Generate 6 virtual future months. For each future month, calculate: `balance = avg_income - avg_expenses - (expected_installments_for_month)`.
    *   Append these 6 months to the `@chart_data` payload, tagging them with `is_projection: true`.
2.  **Chart JS (`assets/js/app.js`)**:
    *   Use Chart.js annotations or a custom plugin to draw a vertical line separating the current month from projections.
    *   Change the background color of the chart area for the projected section to clearly differentiate it.

## Verification & Testing
*   **Unit Tests**: Verify the auto-suggest logic correctly identifies the next installment number based on existing links.
*   **Integration Tests**: Ensure linking a transaction updates the group's progress.
*   **UI Tests**: Verify the chart renders the vertical line and projection logic without JavaScript errors.