defmodule CashLens.Repo.Migrations.AddUserIdToDomainTables do
  @moduledoc """
  Makes every domain table user-owned: `user_id` NOT NULL, a foreign key to
  `users(id)` (`ON DELETE RESTRICT`, so a user that still owns data can never be
  deleted, and the data never cascades away) and an index on `user_id`.

  Existing rows are backfilled to the *operator* user:

    1. the user whose email is in `CASH_LENS_OPERATOR_EMAIL` (case-insensitive);
       the migration raises if the variable is set and no such user exists;
    2. otherwise the only row in `users`;
    3. otherwise, when every domain table is empty, no operator is needed;
    4. otherwise the migration raises, before changing anything, naming the
       variable to set.

  The operator need not be `enabled`; it only has to exist.

  Rollback drops the indexes, foreign keys and `user_id` columns. That discards
  ownership information, which is acceptable because it was derived from a
  single operator.
  """
  use Ecto.Migration

  @tables ~w(
    accounts categories installment_groups transactions balances
    bulk_ignore_patterns transfer_rules rejected_reimbursement_pairs
    recurring_items credit_card_statements imported_files import_runs
  )a

  def up do
    operator_id = resolve_operator!()

    for table <- @tables do
      alter table(table) do
        add :user_id, :binary_id
      end

      if operator_id do
        execute "UPDATE #{table} SET user_id = '#{operator_id}' WHERE user_id IS NULL"
      end

      execute "ALTER TABLE #{table} ALTER COLUMN user_id SET NOT NULL"

      execute """
      ALTER TABLE #{table}
        ADD CONSTRAINT #{table}_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT
      """

      create index(table, [:user_id])
    end
  end

  def down do
    for table <- @tables do
      drop index(table, [:user_id])
      execute "ALTER TABLE #{table} DROP CONSTRAINT #{table}_user_id_fkey"

      alter table(table) do
        remove :user_id
      end
    end
  end

  # Runs before any ALTER, so a failure leaves the schema untouched. Returns
  # the operator id as a UUID string, or nil when no table holds data.
  defp resolve_operator! do
    case System.get_env("CASH_LENS_OPERATOR_EMAIL") do
      email when is_binary(email) and email != "" ->
        case query!("SELECT id::text FROM users WHERE email = $1", [email]) do
          [[id]] -> id
          _ -> raise "CASH_LENS_OPERATOR_EMAIL=#{email} does not match any user"
        end

      _ ->
        case query!("SELECT id::text FROM users LIMIT 2", []) do
          [[id]] -> id
          users -> resolve_without_env!(users)
        end
    end
  end

  defp resolve_without_env!(users) do
    if Enum.all?(@tables, &empty?/1) do
      nil
    else
      raise "domain tables hold data but #{length(users)} users exist (need exactly one): " <>
              "set CASH_LENS_OPERATOR_EMAIL to the email of the user that should own it"
    end
  end

  defp empty?(table), do: query!("SELECT 1 FROM #{table} LIMIT 1", []) == []

  defp query!(sql, params) do
    %{rows: rows} = repo().query!(sql, params)
    rows
  end
end
