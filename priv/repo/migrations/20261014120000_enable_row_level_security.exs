defmodule CashLens.Repo.Migrations.EnableRowLevelSecurity do
  @moduledoc """
  Row-level security on every user-owned table (the 12 tables CL-50 gave a
  `user_id`): RLS is enabled and *forced* (so even the table owner is subject to
  it), with one policy that only lets a row through when

      user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid

  The setting is bound per transaction by `CashLens.Repo`. When it is unset
  (`NULL` or empty) the comparison is never true: no row is visible and no
  insert/update is accepted (the policy applies to `WITH CHECK` as well).

  Superusers and roles with BYPASSRLS skip RLS regardless, which is why the
  runtime role (`priv/repo/roles.sql`) has neither.

  Reversible: `down` drops the policies and turns RLS off.
  """
  use Ecto.Migration

  @tables ~w(
    accounts categories installment_groups transactions balances
    bulk_ignore_patterns transfer_rules rejected_reimbursement_pairs
    recurring_items credit_card_statements imported_files import_runs
  )

  @predicate "user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid"

  def up do
    for table <- @tables do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY user_isolation ON #{table}
        USING (#{@predicate})
        WITH CHECK (#{@predicate})
      """
    end
  end

  def down do
    for table <- @tables do
      execute "DROP POLICY user_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end
end
