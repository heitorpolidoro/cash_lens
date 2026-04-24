defmodule CashLens.Parsers.IngestorTest do
  use CashLens.DataCase, async: true
  alias CashLens.Parsers.Ingestor

  @bb_sample "test/support/fixtures/files/bb_sample.csv"

  describe "parse/2" do
    test "dispatches to bb_csv parser" do
      content = File.read!(@bb_sample)
      transactions = Ingestor.parse(content, "bb_csv")
      assert length(transactions) == 3
      assert Enum.any?(transactions, fn t -> t.description == "BB MM OURO" end)
    end

    test "dispatches to sem_parar_pdf parser" do
      content = "Plano Contratado: SEM PARAR 01/01/26 R$ 50,00"
      transactions = Ingestor.parse(content, "sem_parar_pdf")
      assert length(transactions) == 1
    end

    test "returns error for unknown parser" do
      assert {:error, _} = Ingestor.parse("any", "unknown")
    end
  end

  describe "import_file/2" do
    import CashLens.AccountsFixtures

    test "imports CSV file successfully" do
      account = account_fixture(parser_type: "bb_csv")
      assert {:ok, 3} = Ingestor.import_file(account, @bb_sample)
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 3
    end

    test "handles unparseable files correctly" do
      account = account_fixture(parser_type: "standard_ofx")
      file_path = "test/support/fixtures/files/test.ofx"
      File.write!(file_path, "invalid_data")
      # Most parsers will just return 0 transactions for garbage data
      assert {:ok, 0} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end
  end
end
