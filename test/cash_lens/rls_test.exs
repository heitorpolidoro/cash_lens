defmodule CashLens.RlsTest do
  # The suite itself runs as the unprivileged `cash_lens_app` role; this file
  # proves the isolation that guarantees. Not async: it flips the pinned user of
  # the test process several times, which is cheap but keeps the output readable.
  use CashLens.DataCase, async: false

  import CashLens.UsersFixtures

  alias CashLens.Accounts.Account

  @tables ~w(
    accounts categories installment_groups transactions balances
    bulk_ignore_patterns transfer_rules rejected_reimbursement_pairs
    recurring_items credit_card_statements imported_files import_runs
  )

  @moduletag :no_current_user

  setup do
    a = user_fixture()
    b = user_fixture()
    seed(a.id)
    seed(b.id)
    %{a: a.id, b: b.id}
  end

  defp uuid, do: Ecto.UUID.bingenerate()

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp insert(table, user_id, fields) do
    id = uuid()

    row =
      Map.merge(
        %{id: id, user_id: Ecto.UUID.dump!(user_id), inserted_at: now(), updated_at: now()},
        fields
      )

    {1, _} = Repo.insert_all(table, [row])
    id
  end

  # One row in every user-owned table for `user_id`, parents first.
  defp seed(user_id) do
    Repo.with_user(user_id, fn ->
      account = insert("accounts", user_id, %{})
      other_account = insert("accounts", user_id, %{})
      category = insert("categories", user_id, %{})
      tx_a = insert("transactions", user_id, %{})
      tx_b = insert("transactions", user_id, %{})

      insert("installment_groups", user_id, %{
        description_pattern: "x-#{user_id}",
        installments: 2,
        start_date: ~D[2026-01-01]
      })

      insert("balances", user_id, %{})
      insert("bulk_ignore_patterns", user_id, %{pattern: "x-#{user_id}"})

      insert("transfer_rules", user_id, %{
        source_account_id: account,
        destination_account_id: other_account
      })

      insert("rejected_reimbursement_pairs", user_id, %{
        transaction_a_id: tx_a,
        transaction_b_id: tx_b
      })

      insert("recurring_items", user_id, %{
        category_id: category,
        label: "x-#{user_id}",
        day_of_month: 1,
        amount: Decimal.new("1.00")
      })

      insert("credit_card_statements", user_id, %{account_id: account})
      insert("imported_files", user_id, %{path: "/x-#{user_id}"})
      insert("import_runs", user_id, %{ran_at: now(), file_path: "/x-#{user_id}", status: "ok"})
    end)
  end

  # Raw SQL as the pinned user (`Repo.query/3` itself is not wrapped).
  defp rows(sql, params \\ []) do
    {:ok, %{rows: rows}} = Repo.scoped_query(sql, params)
    rows
  end

  describe "isolation in every user-owned table" do
    for table <- @tables do
      test "#{table}: each user sees only their own rows", %{a: a, b: b} do
        for {me, them} <- [{a, b}, {b, a}] do
          Repo.with_user(me, fn ->
            assert rows("SELECT DISTINCT user_id::text FROM #{unquote(table)}") ==
                     [[me]]

            assert rows(
                     "SELECT count(*) FROM #{unquote(table)} WHERE user_id = $1::uuid",
                     [Ecto.UUID.dump!(them)]
                   ) == [[0]]
          end)
        end
      end

      test "#{table}: nothing is visible when no user is set", %{a: a} do
        # Positive control: the user's own rows exist.
        Repo.with_user(a, fn ->
          assert [[n]] = rows("SELECT count(*) FROM #{unquote(table)}")
          assert n > 0
        end)

        Repo.put_current_user_id(nil)
        assert Repo.query!("SELECT count(*) FROM #{unquote(table)}").rows == [[0]]
      end
    end

    test "the Ecto API is filtered too (all, get, aggregate, preload)", %{a: a, b: b} do
      theirs_id =
        Repo.with_user(b, fn -> Repo.one(from a in Account, limit: 1).id end)

      Repo.with_user(a, fn ->
        refute Repo.get(Account, theirs_id)
        assert Repo.aggregate(Account, :count) == 2
        assert Enum.all?(Repo.all(Account), &(&1.user_id == a))
      end)
    end
  end

  describe "writes" do
    test "inserting a row for another user is rejected", %{a: a, b: b} do
      Repo.with_user(a, fn ->
        assert_raise Postgrex.Error, ~r/row-level security/, fn ->
          insert("accounts", b, %{})
        end
      end)
    end

    test "inserting with no user set is rejected", %{a: a} do
      Repo.put_current_user_id(nil)

      assert_raise Postgrex.Error, ~r/row-level security/, fn ->
        Repo.insert_all("accounts", [
          %{id: uuid(), user_id: Ecto.UUID.dump!(a), inserted_at: now(), updated_at: now()}
        ])
      end
    end

    test "a user cannot move a row to another user", %{a: a, b: b} do
      Repo.with_user(a, fn ->
        assert_raise Postgrex.Error, ~r/row-level security/, fn ->
          Repo.update_all("accounts", set: [user_id: Ecto.UUID.dump!(b)])
        end
      end)
    end

    test "update and delete under A touch none of B's rows", %{a: a, b: b} do
      Repo.with_user(a, fn ->
        {updated, _} = Repo.update_all("accounts", set: [name: "touched"])
        assert updated == 2
        {deleted, _} = Repo.delete_all("categories")
        assert deleted == 1
      end)

      Repo.with_user(b, fn ->
        assert rows("SELECT count(*) FROM accounts WHERE name = 'touched'") ==
                 [[0]]

        assert rows("SELECT count(*) FROM categories") == [[1]]
      end)
    end
  end

  describe "the binding" do
    # Outside the sandbox, on a one-connection pool: the next checkout of the
    # very same connection must not see the previous user. The explicit reset
    # the sandbox needs is switched off, so only transaction-locality is tested.
    test "does not leak to the next checkout of a pooled connection", %{a: a} do
      Application.put_env(:cash_lens, :sql_sandbox, false)
      on_exit(fn -> Application.put_env(:cash_lens, :sql_sandbox, true) end)

      {:ok, pool} =
        Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)

      Repo.put_dynamic_repo(pool)
      on_exit(fn -> Repo.put_dynamic_repo(Repo) end)

      Repo.put_current_user_id(a)
      assert [] = Repo.all(Account)

      assert Repo.query!("SELECT current_setting('app.current_user_id', true)").rows in [
               [[nil]],
               [[""]]
             ]

      assert Repo.query!("SELECT count(*) FROM accounts").rows == [[0]]

      Repo.put_dynamic_repo(Repo)
      Supervisor.stop(pool)
    end

    test "with_user restores the previous user, also when nested", %{a: a, b: b} do
      Repo.put_current_user_id(a)

      Repo.transaction(fn ->
        Repo.with_user(b, fn ->
          assert Enum.all?(Repo.all(Account), &(&1.user_id == b))
        end)

        assert Repo.current_user_id() == a
        assert Enum.all?(Repo.all(Account), &(&1.user_id == a))
      end)
    end

    test "a transaction is bound too, and a Multi keeps its own result keys", %{a: a} do
      Repo.put_current_user_id(a)

      assert {:ok, %{count: 2}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:count, fn repo, _ ->
                 {:ok, repo.aggregate(Account, :count)}
               end)
               |> Repo.transaction()
    end

    test "a constraint error comes back as a changeset and the connection stays usable", %{a: a} do
      alias CashLens.Transactions.BulkIgnorePattern

      Repo.put_current_user_id(a)
      attrs = %{pattern: "dup-#{a}"}

      assert {:ok, _} =
               %BulkIgnorePattern{user_id: CashLens.Repo.current_user_id()}
               |> BulkIgnorePattern.changeset(attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               %BulkIgnorePattern{user_id: CashLens.Repo.current_user_id()}
               |> BulkIgnorePattern.changeset(attrs)
               |> Repo.insert()

      assert %{pattern: ["has already been taken"]} = errors_on(changeset)
      assert Repo.aggregate(Account, :count) == 2
    end
  end

  describe "the schema" do
    test "every user-owned table has RLS enabled and forced with one user_id policy" do
      rows =
        Repo.query!(
          """
          SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity,
                 (SELECT count(*) FROM pg_policies p
                   WHERE p.tablename = c.relname AND p.schemaname = 'public'
                     AND p.qual LIKE '%app.current_user_id%' AND p.with_check LIKE '%app.current_user_id%')
          FROM pg_class c
          WHERE c.relname = ANY($1) AND c.relkind = 'r'
          ORDER BY c.relname
          """,
          [@tables]
        ).rows

      assert length(rows) == length(@tables)

      assert Enum.all?(rows, fn [_table, enabled, forced, policies] ->
               enabled and forced and policies == 1
             end)
    end

    test "every table with a user_id column is covered (new tables must opt in)" do
      %{rows: rows} =
        Repo.query!("""
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name = 'user_id'
        """)

      with_user_id = rows |> List.flatten() |> MapSet.new()

      # Account tables are reached before anyone is logged in, so they are the
      # documented exceptions (docs/security.md).
      exceptions = MapSet.new(~w(user_tokens login_attempts))

      uncovered =
        with_user_id |> MapSet.difference(MapSet.new(@tables)) |> MapSet.difference(exceptions)

      assert MapSet.to_list(uncovered) == []
    end
  end
end
