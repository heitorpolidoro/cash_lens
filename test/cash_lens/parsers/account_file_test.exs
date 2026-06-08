defmodule CashLens.Parsers.AccountFileTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.AccountFile

  describe "parse/1" do
    test "parses bank and account keys regardless of order" do
      content = "account: Conta Corrente\nbank: Banco do Brasil\n"

      assert {:ok, %{bank: "Banco do Brasil", account: "Conta Corrente"}} =
               AccountFile.parse(content)
    end

    test "ignores blank lines and comments" do
      content = "# minha conta\n\nbank: Bradesco\n# obs\naccount: Conta Corrente\n"
      assert {:ok, %{bank: "Bradesco", account: "Conta Corrente"}} = AccountFile.parse(content)
    end

    test "trims whitespace around keys and values" do
      content = "  bank :  Banco do Brasil  \n  account :  Ourocard \n"
      assert {:ok, %{bank: "Banco do Brasil", account: "Ourocard"}} = AccountFile.parse(content)
    end

    test "errors when bank is missing" do
      assert {:error, msg} = AccountFile.parse("account: Conta Corrente\n")
      assert msg =~ "bank"
    end

    test "errors when account is missing" do
      assert {:error, msg} = AccountFile.parse("bank: Bradesco\n")
      assert msg =~ "account"
    end

    test "errors when a value is empty" do
      assert {:error, _} = AccountFile.parse("bank:\naccount: X\n")
    end
  end

  describe "read/1 and exists?/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "acctfile_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "exists?/1 reflects presence of .account", %{dir: dir} do
      refute AccountFile.exists?(dir)
      File.write!(Path.join(dir, ".account"), "bank: X\naccount: Y\n")
      assert AccountFile.exists?(dir)
    end

    test "read/1 parses the .account in a directory", %{dir: dir} do
      File.write!(Path.join(dir, ".account"), "bank: Bradesco\naccount: Conta Corrente\n")
      assert {:ok, %{bank: "Bradesco", account: "Conta Corrente"}} = AccountFile.read(dir)
    end

    test "read/1 errors when file is absent", %{dir: dir} do
      assert {:error, _} = AccountFile.read(dir)
    end
  end
end
