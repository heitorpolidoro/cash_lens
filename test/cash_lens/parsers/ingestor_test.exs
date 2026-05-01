defmodule CashLens.Parsers.IngestorTest do
  use CashLens.DataCase, async: false
  import Mox
  alias CashLens.Parsers.Ingestor

  setup :verify_on_exit!

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
      file_path = "test/support/fixtures/files/test_#{account.id}.ofx"
      File.write!(file_path, "invalid_data")
      # Most parsers will just return 0 transactions for garbage data
      assert {:ok, 0} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "imports Latin1 encoded files" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/latin1_#{account.id}.csv"
      # "Data,Valor,Hist\n" in Latin1
      content = <<68, 97, 116, 97, 44, 86, 97, 108, 111, 114, 44, 72, 105, 115, 116, 10>>
      File.write!(file_path, content)
      assert {:ok, 0} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "adds periods for BB related accounts" do
      account = account_fixture(parser_type: "bb_csv")
      # Create related accounts
      account_fixture(name: "BB MM Ouro")
      account_fixture(name: "BB Rende Fácil")

      content =
        "Data,Dep,Term,Hist,Doc,Valor,\n01/01/2026,0,0,BB MM OURO,1,-100.00,\n02/01/2026,0,0,BB RENDE FACIL,1,50.00,\n"

      file_path = "test/support/fixtures/files/bb_related_#{account.id}.csv"
      File.write!(file_path, content)

      assert {:ok, 2} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "adds periods for BB related accounts but handles missing accounts" do
      account = account_fixture(parser_type: "bb_csv")
      # DO NOT create related accounts

      content =
        "Data,Dep,Term,Hist,Doc,Valor,\n01/01/2026,0,0,BB MM OURO,1,-100.00,\n02/01/2026,0,0,BB RENDE FACIL,1,50.00,\n"

      file_path = "test/support/fixtures/files/bb_missing_#{account.id}.csv"
      File.write!(file_path, content)

      assert {:ok, 2} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "returns error when file cannot be read" do
      account = account_fixture()

      assert {:error, "Could not read file: enoent"} =
               Ingestor.import_file(account, "non_existent_file.csv")
    end

    test "handles pdftotext failure branch" do
      # If parser_type is sem_parar_pdf but file is not a valid PDF or pdftotext fails
      account = account_fixture(parser_type: "sem_parar_pdf")
      file_path = "test/support/fixtures/files/fail_#{account.id}.pdf"
      content = "not a pdf content"
      File.write!(file_path, content)

      expect(CashLens.Parsers.PDFConverterMock, :convert, fn ^file_path ->
        {:error, :failed}
      end)

      # pdftotext will fail, returning the original content
      assert {:ok, 0} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "imports CSV with no transactions" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/empty_#{account.id}.csv"
      File.write!(file_path, "Data,Dep,Term,Hist,Doc,Valor,\n")
      assert {:ok, 0} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "imports PDF using sem_parar_pdf parser_type" do
      account = account_fixture(parser_type: "sem_parar_pdf")
      file_path = "test/support/fixtures/files/sem_parar_#{account.id}.pdf"
      content = "Plano Contratado 01/01/26 R$ 10,00\n"
      File.write!(file_path, content)

      expect(CashLens.Parsers.PDFConverterMock, :convert, fn ^file_path ->
        {:ok, content}
      end)

      # Even if pdftotext fails, it falls back to content and parses
      assert {:ok, 1} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "handles unknown file extension with generic fallback" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/generic_#{account.id}.txt"
      File.write!(file_path, "Data,Dep,Term,Hist,Doc,Valor,\n")
      assert {:ok, 0} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "handles invalid UTF-8 by converting from Latin1" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/invalid_utf8_#{account.id}.csv"
      # \xE1 is 'á' in Latin1 but invalid in UTF-8
      content = "Data,Dep,Term,Hist,Doc,Valor,\n01/01/2026,0,0,M\xE1-formado,1,-10.00,\n"
      File.write!(file_path, content)

      assert {:ok, 1} = Ingestor.import_file(account, file_path)

      tx = CashLens.Repo.one(CashLens.Transactions.Transaction)
      assert tx.description == "M\u00E1-formado"
      File.rm!(file_path)
    end
  end
end
