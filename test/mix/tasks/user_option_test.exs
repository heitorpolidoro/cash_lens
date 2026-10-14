defmodule Mix.Tasks.UserOptionTest do
  @moduledoc """
  The maintenance mix tasks and the seeds act for one explicit user: `--user
  <email>` (or `CASH_LENS_OPERATOR_EMAIL` for the seeds), the only user when
  there is a single one, and nothing at all otherwise.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import ExUnit.CaptureIO

  alias CashLens.Categories.Category
  alias CashLens.Tenancy
  alias CashLens.Transactions.Transaction
  alias Mix.Tasks.MigrateCreditCardTransfers

  @env "CASH_LENS_OPERATOR_EMAIL"

  @sample """
  Data,Dependência Origem,Term. Origem,Histórico,Documento,Valor,
  20/02/2026,0000,0000,SALDO ANTERIOR,,0.00,
  24/02/2026,1234,5678,COMPRA DO USUARIO,123.456,-150.00,
  """

  defp import_folder do
    root = Path.join(System.tmp_dir!(), "user_opt_#{System.unique_integer([:positive])}")
    dir = Path.join(root, "bb")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".account"),
      "bank: Banco do Brasil\naccount: Conta Corrente\nparser: bb_csv\n"
    )

    File.write!(Path.join(dir, "extrato.csv"), @sample)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp account_for(user) do
    account_fixture(%{
      user: user,
      bank: "Banco do Brasil",
      name: "Conta Corrente",
      parser_type: "bb_csv"
    })
  end

  defp rows(user, schema), do: Tenancy.acting_as(user, fn -> Repo.all(schema) end)

  defp run_task(module, args) do
    capture_io(fn ->
      ExUnit.CaptureLog.capture_log(fn -> module.run(args) end)
    end)
  end

  describe "mix cash_lens.import --user" do
    test "creates rows owned by the named user" do
      %{a: a, b: b} = cross_tenant()
      account_for(a)
      account_for(b)

      run_task(Mix.Tasks.CashLens.Import, ["--user", b.email, import_folder()])

      assert [tx] = rows(b, Transaction)
      assert tx.user_id == b.id
      assert rows(a, Transaction) == []
    end

    test "aborts with several users and no --user, writing nothing" do
      %{a: a, b: b} = cross_tenant()
      account_for(a)
      account_for(b)
      folder = import_folder()

      assert_raise Mix.Error, ~r/--user <email>/, fn ->
        run_task(Mix.Tasks.CashLens.Import, [folder])
      end

      assert rows(a, Transaction) == []
      assert rows(b, Transaction) == []
    end

    test "aborts for an unknown email, writing nothing" do
      %{a: a} = cross_tenant()
      account_for(a)
      folder = import_folder()

      assert_raise Mix.Error, ~r/no user has the email/, fn ->
        run_task(Mix.Tasks.CashLens.Import, ["--user", "ghost@example.com", folder])
      end

      assert rows(a, Transaction) == []
    end

    test "uses the only user when --user is omitted" do
      user = CashLens.Repo.get!(CashLens.Users.User, current_user_id())
      account_for(user)

      run_task(Mix.Tasks.CashLens.Import, [import_folder()])

      assert [tx] = rows(user, Transaction)
      assert tx.user_id == user.id
    end

    test "prints usage without a path" do
      assert catch_exit(run_task(Mix.Tasks.CashLens.Import, [])) == {:shutdown, 2}
    end
  end

  describe "the other maintenance tasks" do
    test "all abort when several users exist and no --user is given" do
      cross_tenant()

      for module <- [
            Mix.Tasks.CashLens.BackfillStatements,
            Mix.Tasks.CashLens.MigrateOurocardTxt,
            Mix.Tasks.CashLens.RecomputeCompetencia,
            Mix.Tasks.CashLens.ReconcilePendingStatements,
            MigrateCreditCardTransfers
          ] do
        assert_raise Mix.Error, ~r/several users/, fn -> run_task(module, []) end
      end
    end

    test "recompute_competencia and reconcile_pending_statements accept --user" do
      %{b: b} = cross_tenant()

      assert run_task(Mix.Tasks.CashLens.RecomputeCompetencia, ["--user", b.email]) =~
               "for 0 statement(s)"

      assert run_task(Mix.Tasks.CashLens.ReconcilePendingStatements, ["--user", b.email]) =~
               "Reconciled: 0"
    end

    test "migrate_ourocard_txt only switches the named user's accounts" do
      %{a: a, b: b} = cross_tenant()
      account_a = account_fixture(%{user: a, parser_type: "ourocard_ofx", is_credit_card: true})
      account_b = account_fixture(%{user: b, parser_type: "ourocard_ofx", is_credit_card: true})

      run_task(Mix.Tasks.CashLens.MigrateOurocardTxt, ["--user", b.email])

      parser_of = fn user, account ->
        Tenancy.acting_as(user, fn ->
          CashLens.Accounts.get_account!(user, account.id).parser_type
        end)
      end

      assert parser_of.(b, account_b) == "ourocard_txt"
      assert parser_of.(a, account_a) == "ourocard_ofx"
    end

    test "migrate_credit_card_transfers runs for the named user" do
      %{b: b} = cross_tenant()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          MigrateCreditCardTransfers.run(["--user", b.email])
        end)

      assert log =~ "cartao-de-credito"
    end

    test "backfill_statements fails on a missing path but resolves the user first" do
      %{b: b} = cross_tenant()

      assert catch_exit(
               run_task(Mix.Tasks.CashLens.BackfillStatements, [
                 "--user",
                 b.email,
                 "/nonexistent/path"
               ])
             ) == {:shutdown, 1}
    end
  end

  describe "priv/repo/seeds.exs" do
    setup do
      previous = System.get_env(@env)

      on_exit(fn ->
        if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
      end)

      System.delete_env(@env)
      :ok
    end

    defp seed, do: Code.eval_file("priv/repo/seeds.exs")

    test "creates the base categories owned by CASH_LENS_OPERATOR_EMAIL's user" do
      %{a: a, b: b} = cross_tenant()
      System.put_env(@env, b.email)

      seed()

      categories = rows(b, Category)

      assert Enum.sort(Enum.map(categories, & &1.slug)) == [
               "cartao-de-credito",
               "initial_value",
               "transfer"
             ]

      assert Enum.all?(categories, &(&1.user_id == b.id))
      assert rows(a, Category) == []
    end

    test "aborts with several users and no CASH_LENS_OPERATOR_EMAIL" do
      %{a: a, b: b} = cross_tenant()

      assert_raise Mix.Error, ~r/several users/, fn -> seed() end

      assert rows(a, Category) == []
      assert rows(b, Category) == []
    end

    test "uses the only user when the variable is unset" do
      user = CashLens.Repo.get!(CashLens.Users.User, current_user_id())
      seed()
      assert length(rows(user, Category)) == 3
    end
  end

  defp current_user_id, do: CashLens.Repo.current_user_id()
end
