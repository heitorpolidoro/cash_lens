# CashLens LiveView Refactoring Plan

## 1. Structure & Componentization

### 1.1 Extract Templates
The `TransactionLive.Index` is over 1400 lines long, with the entire HEEx template embedded in `render/1`.
*   **Action:** Move the `~H"""..."""` content to a dedicated `index.html.heex` file.
*   **Action:** Apply the same to `AccountLive.Index`, `CategoryLive.Index`, etc.

### 1.2 Create Reusable Functional Components
The templates contain highly repetitive and complex UI blocks that should be extracted into smaller components.
*   **Action:** Create a `CashLensWeb.TransactionComponents` module (or similar) to house specific components like:
    *   `<.transaction_filters />`
    *   `<.summary_cards />`
    *   `<.transaction_table />`
*   **Action:** Use the existing `CashLensWeb.CoreComponents.table/1` generic component or adapt it, instead of hand-coding `<table class="table table-zebra">` everywhere.

### 1.3 Extract Modals to LiveComponents
The current views manage the state of several complex modals (Import, Category, Reimbursement, Transfer) entirely within the main LiveView. This bloats the main process and increases memory usage per connection.
*   **Action:** Convert complex modals into Stateful LiveComponents (e.g., `CashLensWeb.TransactionLive.ImportComponent`). This isolates their state (`assigns`) and events, keeping the main LiveView lean.

## 2. UX Flow & Tailwind Implementation

### 2.1 CSS / Tailwind Abstractions
DaisyUI is used heavily (e.g., `btn`, `stats`, `join`), but there are massive inline class strings that make the HTML hard to read.
*   **Action:** Move common grouped classes into custom Tailwind `@apply` directives in `app.css` or encapsulate them inside `CoreComponents`.

### 2.2 Modal Architecture
Modals currently rely on `assigns` (like `@show_import_modal`, `@show_reimbursement_modal`) and manual `phx-click="close_modal"` events.
*   **Action:** Phoenix 1.7+ CoreComponents `.modal` usually uses `JS.show/JS.hide` to avoid a server roundtrip just to close a modal. Ensure toggling modals visually is handled client-side where possible, and only clear the state on the server when necessary (e.g., on submit).

## 3. LiveView Performance & State Management

### 3.1 N+1 and Heavy Calculations in LiveView
`TransactionLive.Index` performs heavy lifting in its `handle_event` callbacks:
*   `calculate_summary/1` is called on almost every filter change. It queries `Transactions.get_monthly_summary`, does an in-memory `length(Transactions.list_transactions(...))`, and loops through accounts to find balances.
*   **Action:** Push this logic to a specific `Accounting` or `Transactions` context function that performs a single, optimized SQL query (using aggregations like `COUNT`, `SUM`).

### 3.2 In-Memory Sorting and Filtering
The `update_reimbursement_linker_list/1` function queries large datasets and performs complex sorting and filtering in Elixir memory (`Enum.sort`, `Enum.filter`).
*   **Action:** Move this logic to Ecto queries. The database is much faster at sorting and filtering exact matches.

### 3.3 Business Logic Leakage
*   The `process_transactions_data/2` function contains hardcoded strings ("BB MM OURO", "BB RENDE FÁCIL") inside the LiveView. This is a severe domain leakage.
*   **Action:** Move parsing and auto-categorization routing to the `Parsers.Ingestor` or `Transactions.AutoCategorizer` context.
*   The HEEx template contains business logic like `<% balance = Decimal.sub(@summary.income, @summary.expenses) %>`.
*   **Action:** Calculate this in the Context or in the LiveView `mount/handle_params` and assign it directly. Templates should only render data.

### 3.4 Event Granularity
There are inline forms triggering `phx-change="apply_filters"` which is good, but combining it with debounced inputs can sometimes cause race conditions if the server is slow to respond to the heavy `calculate_summary` calls. Optimizing the DB queries will fix the root cause.