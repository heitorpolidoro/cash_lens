# Credo Strict Resolution Plan

## Objective
Resolve all 53 Code Quality issues identified by `mix credo --strict` to restore the CI pipeline to a passing state, leveraging a specialized subagent for rapid and efficient batch execution.

## Background & Motivation
The recent unification of local and CI quality checks introduced `credo --strict`. While this ensures a high standard of code readability and design, it immediately broke the CI pipeline due to pre-existing technical debt (e.g., alias ordering, deep nesting, expensive `length/1` checks).

## Scope & Impact
The scope includes approximately 93 files, with 53 specific issues categorized into:
- **Warnings (11):** Expensive `length/1` checks.
- **Readability (12):** Missing `@moduledoc`, improper alias ordering, and trailing whitespace.
- **Software Design (13):** Nested modules not aliased at the top.
- **Refactoring Opportunities (17):** Cyclomatic complexity, deep nesting, and inefficient Enumerable chains.

## Proposed Solution
We will delegate the resolution to the `generalist` subagent. The process will be executed in targeted batches to ensure safety and prevent regressions:

### Phase 1: Automated & Syntax Fixes (Low Risk)
The subagent will fix:
1. Reordering aliases alphabetically.
2. Adding `@moduledoc false` (or descriptive docs) to modules missing them.
3. Removing trailing whitespaces.
4. Refactoring `length(list) > 0` to `list != []` and `length(list) == 0` to `list == []`.

### Phase 2: Structural Cleanups (Medium Risk)
The subagent will fix:
1. Moving nested module aliases to the top of the invoking module.
2. Replacing `Enum.map/2 |> Enum.join/2` with `Enum.map_join/3`.
3. Removing negated conditions in `if/else` blocks.

### Phase 3: Complex Refactoring (High Risk)
The subagent will carefully refactor functions flagged for:
1. Deep nesting (extracting blocks into private functions).
2. High cyclomatic complexity (pattern matching, guard clauses, or extracting helper functions).

## Verification & Testing
After the subagent completes the tasks, we will run `mix quality_check` to guarantee a clean output (0 issues) and 100% passing tests.

## Rollback Strategy
If any complex refactoring breaks the test suite and cannot be easily resolved by the subagent, we will temporarily revert that specific file and disable the `--strict` flag until it can be manually addressed.