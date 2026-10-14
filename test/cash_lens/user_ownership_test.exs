defmodule CashLens.UserOwnershipTest do
  use CashLens.DataCase, async: true

  import CashLens.UsersFixtures

  alias CashLens.Ownership

  @tables_and_schemas [
    {"accounts", CashLens.Accounts.Account},
    {"categories", CashLens.Categories.Category},
    {"installment_groups", CashLens.Installments.InstallmentGroup},
    {"transactions", CashLens.Transactions.Transaction},
    {"balances", CashLens.Accounting.Balance},
    {"bulk_ignore_patterns", CashLens.Transactions.BulkIgnorePattern},
    {"transfer_rules", CashLens.Transactions.TransferRule},
    {"rejected_reimbursement_pairs", CashLens.Transactions.RejectedReimbursementPair},
    {"recurring_items", CashLens.Forecast.RecurringItem},
    {"credit_card_statements", CashLens.CreditCards.Statement},
    {"imported_files", CashLens.Imports.ImportedFile},
    {"import_runs", CashLens.Imports.ImportRun}
  ]

  for {table, schema} <- @tables_and_schemas do
    describe table do
      test "user_id is NOT NULL" do
        %{rows: rows} =
          Repo.query!(
            "SELECT is_nullable FROM information_schema.columns " <>
              "WHERE table_name = $1 AND column_name = 'user_id'",
            [unquote(table)]
          )

        assert rows == [["NO"]]
      end

      test "user_id has a foreign key to users" do
        %{rows: rows} =
          Repo.query!(
            """
            SELECT confrelid::regclass::text, confdeltype::text
            FROM pg_constraint
            WHERE contype = 'f' AND conrelid = $1::text::regclass
              AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                  WHERE attrelid = $1::text::regclass AND attname = 'user_id')]
            """,
            [unquote(table)]
          )

        # "r" is ON DELETE RESTRICT.
        assert rows == [["users", "r"]]
      end

      test "user_id is indexed" do
        %{rows: rows} =
          Repo.query!(
            "SELECT indexdef FROM pg_indexes WHERE tablename = $1 AND indexdef LIKE '%(user_id)'",
            [unquote(table)]
          )

        assert rows != []
      end

      test "the schema declares belongs_to :user" do
        assert :user in unquote(schema).__schema__(:associations)
        assert unquote(schema).__schema__(:association, :user).related == CashLens.Users.User
      end
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  describe "foreign key enforcement" do
    # Row-level security rejects a row whose user_id is not the current user
    # before the foreign key is looked at, so act as the unknown user.
    test "an account with an unknown user_id is rejected" do
      ghost = Ecto.UUID.generate()

      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        Repo.with_user(ghost, fn ->
          Repo.insert_all(CashLens.Accounts.Account, [
            %{
              id: Ecto.UUID.generate(),
              name: "x",
              bank: "b",
              balance: 0,
              user_id: ghost,
              inserted_at: now(),
              updated_at: now()
            }
          ])
        end)
      end
    end

    test "a transaction with an unknown user_id is rejected" do
      account = CashLens.AccountsFixtures.account_fixture()
      ghost = Ecto.UUID.generate()

      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        Repo.with_user(ghost, fn ->
          Repo.insert_all(CashLens.Transactions.Transaction, [
            %{
              id: Ecto.UUID.generate(),
              date: ~D[2026-01-01],
              amount: Decimal.new("1.00"),
              description: "x",
              account_id: account.id,
              user_id: ghost,
              inserted_at: now(),
              updated_at: now()
            }
          ])
        end)
      end
    end

    test "a user that owns an account cannot be deleted" do
      user = user_fixture()
      Ownership.put_user_id(user.id)
      account = CashLens.AccountsFixtures.account_fixture()
      assert account.user_id == user.id

      assert_raise Ecto.ConstraintError, ~r/accounts_user_id_fkey/, fn ->
        Repo.delete!(user)
      end
    end
  end

  describe "CashLens.Ownership" do
    test "an insert without user_id fails instead of getting an owner" do
      assert_raise Postgrex.Error, ~r/not_null_violation|null value|row-level security/, fn ->
        Repo.insert!(%CashLens.Categories.Category{name: "Orphan", slug: "orphan"})
      end
    end

    test "the owner-fallback API is gone" do
      refute function_exported?(Ownership, :assign, 1)
      refute function_exported?(Ownership, :current_user_id!, 0)
      refute function_exported?(Ownership, :pin_operator!, 0)
      refute function_exported?(Ownership, :operator_user!, 0)
      assert Application.get_env(:cash_lens, :auto_create_owner) == nil
    end

    test "Repo.with_user/2 still pins and restores the user" do
      user = user_fixture()
      before = Repo.current_user_id()
      assert Repo.with_user(user.id, fn -> Repo.current_user_id() end) == user.id
      assert Repo.current_user_id() == before
    end

    test "domain_schemas lists the 12 owned schemas" do
      assert length(Ownership.domain_schemas()) == 12
      assert CashLens.Transactions.Transaction in Ownership.domain_schemas()
    end
  end
end
