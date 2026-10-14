defmodule CashLens.Parsers.ImportPerUserTest do
  @moduledoc """
  Two users import different files through the same pipeline: every row each
  import creates is owned by its importer and nothing crosses between them.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures

  alias CashLens.Accounting.Balance
  alias CashLens.Imports.ImportedFile
  alias CashLens.Imports.ImportRun
  alias CashLens.Parsers.DirectoryImporter
  alias CashLens.Tenancy
  alias CashLens.Transactions.Transaction

  @sample_a """
  Data,Dependência Origem,Term. Origem,Histórico,Documento,Valor,
  20/02/2026,0000,0000,SALDO ANTERIOR,,0.00,
  24/02/2026,1234,5678,COMPRA DE A,123.456,-150.00,
  25/02/2026,0000,0000,SALARIO DE A,999.000,500.00,
  """

  @sample_b """
  Data,Dependência Origem,Term. Origem,Histórico,Documento,Valor,
  20/02/2026,0000,0000,SALDO ANTERIOR,,0.00,
  24/02/2026,1234,5678,COMPRA DE B,321.654,-70.00,
  26/02/2026,0000,0000,PIX DE B,777.000,40.00,
  27/02/2026,0000,0000,OUTRO PIX DE B,888.000,10.00,
  """

  defp folder(label, content) do
    root = Path.join(System.tmp_dir!(), "per_user_#{label}_#{System.unique_integer([:positive])}")
    dir = Path.join(root, "bb")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".account"),
      "bank: Banco do Brasil\naccount: Conta Corrente\nparser: bb_csv\n"
    )

    File.write!(Path.join(dir, "#{label}.csv"), content)
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

  defp owned_rows(user, schema), do: Tenancy.acting_as(user, fn -> Repo.all(schema) end)

  setup do
    {:ok, cross_tenant()}
  end

  test "every row created by an import is owned by its importer", %{a: a, b: b} do
    account_a = account_for(a)
    account_b = account_for(b)

    result_a =
      Tenancy.acting_as(a, fn ->
        DirectoryImporter.run(a, folder("a", @sample_a), skip_installments: true)
      end)

    result_b =
      Tenancy.acting_as(b, fn ->
        DirectoryImporter.run(b, folder("b", @sample_b), skip_installments: true)
      end)

    assert result_a.errors == []
    assert result_b.errors == []

    for {user, other, account, count} <- [{a, b, account_a, 2}, {b, a, account_b, 3}] do
      for schema <- [Transaction, ImportedFile, ImportRun, Balance] do
        rows = owned_rows(user, schema)
        assert rows != [], "#{inspect(schema)} has no rows for its importer"
        assert Enum.all?(rows, &(&1.user_id == user.id))
        refute Enum.any?(rows, &(&1.user_id == other.id))
      end

      transactions = owned_rows(user, Transaction)
      assert length(transactions) == count
      assert Enum.all?(transactions, &(&1.account_id == account.id))
    end

    descriptions = fn user -> user |> owned_rows(Transaction) |> Enum.map(& &1.description) end
    assert Enum.all?(descriptions.(a), &String.contains?(&1, "A"))
    assert Enum.all?(descriptions.(b), &String.contains?(&1, "B"))
  end

  test "no transfer pair links rows of two users", %{a: a, b: b} do
    account_for(a)
    account_for(b)

    Tenancy.acting_as(a, fn ->
      DirectoryImporter.run(a, folder("a", @sample_a), skip_installments: true)
    end)

    Tenancy.acting_as(b, fn ->
      DirectoryImporter.run(b, folder("b", @sample_b), skip_installments: true)
    end)

    keys = fn user ->
      user |> owned_rows(Transaction) |> Enum.map(& &1.transfer_key) |> Enum.reject(&is_nil/1)
    end

    assert keys.(a) -- keys.(b) == keys.(a)
  end

  test "B's import cannot resolve A's account", %{a: a, b: b} do
    account_for(a)

    result =
      Tenancy.acting_as(b, fn ->
        DirectoryImporter.run(b, folder("b", @sample_b), skip_installments: true)
      end)

    assert [error] = result.errors
    assert error =~ "não encontrada"
    assert owned_rows(b, Transaction) == []
    assert owned_rows(a, Transaction) == []
  end
end
