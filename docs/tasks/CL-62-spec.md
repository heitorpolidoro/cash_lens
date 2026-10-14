# CL-62 — Remove operator.ex from the user scoping audit allow-list

The operator helper (`CashLens.Operator`: `user!/1`, `parse_args/1`, private `pin/1`) moves into `CashLens.Ownership` as `operator_user!/1` and `operator_parse_args/1`, as the CL-51 spec says. Behavior is unchanged: an email returns that user or raises `Mix.Error`; `nil` returns the only user or raises `Mix.Error` for none or several; the user is pinned through `Repo.put_current_user_id/1`; it never creates a user.

Files touched:
- `lib/cash_lens/ownership.ex`: gains the two functions (with docs, usage message, aliases); moduledoc reference updated.
- `lib/cash_lens/operator.ex`: deleted.
- `lib/mix/tasks/` (migrate_credit_card_transfers, cash_lens.recompute_competencia, cash_lens.import, cash_lens.backfill_statements, cash_lens.migrate_ourocard_txt, cash_lens.reconcile_pending_statements): `CashLens.Operator.*` calls become `CashLens.Ownership.operator_*`.
- `priv/repo/seeds.exs`: drop `alias CashLens.Operator` (line 2); line 7 calls `CashLens.Ownership.operator_user!(System.get_env("CASH_LENS_OPERATOR_EMAIL"))` (or aliases Ownership). Without this, `mix run priv/repo/seeds.exs` and `mix ecto.setup` break.
- `test/cash_lens/operator_test.exs`: moved/merged into an Ownership test file, calling the new functions. `test/mix/tasks/user_option_test.exs` keeps passing.
- `test/cash_lens/user_scoping_audit_test.exs`: drop the `lib/cash_lens/operator.ex` entry and its comment; assertion becomes `length(@allow_list) == 6`.

Test criteria: the audit test passes with 6 entries (users, audit, health, privacy, ownership, application); relocated operator tests and `user_option_test.exs` pass; grep of `lib/cash_lens` and `lib/cash_lens_web` finds no `operator_user!` call from contexts or the web layer (only the six mix tasks and `priv/repo/seeds.exs` call it); `mix run priv/repo/seeds.exs` still runs against a test/dev DB; `mix test` and `mix precommit` pass.

Out of scope: changing `--user` / `CASH_LENS_OPERATOR_EMAIL` semantics. Arity is /1 (email or nil), not /0, because tasks pass `--user`.
