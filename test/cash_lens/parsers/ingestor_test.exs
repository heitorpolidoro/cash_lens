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
      assert {:ok, %{imported: 3, failed: []}} = Ingestor.import_file(account, @bb_sample)
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 3
    end

    test "handles unparseable files correctly" do
      account = account_fixture(parser_type: "standard_ofx")
      file_path = "test/support/fixtures/files/test_#{account.id}.ofx"
      File.write!(file_path, "invalid_data")
      # Most parsers will just return 0 transactions for garbage data
      assert {:ok, %{imported: 0}} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "imports Latin1 encoded files" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/latin1_#{account.id}.csv"
      # "Data,Valor,Hist\n" in Latin1
      content = <<68, 97, 116, 97, 44, 86, 97, 108, 111, 114, 44, 72, 105, 115, 116, 10>>
      File.write!(file_path, content)
      assert {:ok, %{imported: 0}} = Ingestor.import_file(account, file_path)
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

      assert {:ok, %{imported: 2}} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "adds periods for BB related accounts but handles missing accounts" do
      account = account_fixture(parser_type: "bb_csv")
      # DO NOT create related accounts

      content =
        "Data,Dep,Term,Hist,Doc,Valor,\n01/01/2026,0,0,BB MM OURO,1,-100.00,\n02/01/2026,0,0,BB RENDE FACIL,1,50.00,\n"

      file_path = "test/support/fixtures/files/bb_missing_#{account.id}.csv"
      File.write!(file_path, content)

      assert {:ok, %{imported: 2}} = Ingestor.import_file(account, file_path)
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
      assert {:ok, %{imported: _}} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "imports CSV with no transactions" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/empty_#{account.id}.csv"
      File.write!(file_path, "Data,Dep,Term,Hist,Doc,Valor,\n")
      assert {:ok, %{imported: _}} = Ingestor.import_file(account, file_path)
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
      assert {:ok, %{imported: _}} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)
    end

    test "handles unknown file extension with generic fallback" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/generic_#{account.id}.txt"
      on_exit(fn -> File.rm(file_path) end)
      File.write!(file_path, "Data,Dep,Term,Hist,Doc,Valor,\n")
      assert {:ok, %{imported: _}} = Ingestor.import_file(account, file_path)
    end

    test "handles invalid UTF-8 by converting from Latin1" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/invalid_utf8_#{account.id}.csv"
      on_exit(fn -> File.rm(file_path) end)
      # \xE1 is 'á' in Latin1 but invalid in UTF-8
      content = "Data,Dep,Term,Hist,Doc,Valor,\n01/01/2026,0,0,M\xE1-formado,1,-10.00,\n"
      File.write!(file_path, content)

      assert {:ok, %{imported: _}} = Ingestor.import_file(account, file_path)

      tx = CashLens.Repo.one(CashLens.Transactions.Transaction)
      assert tx.description == "M\u00E1-formado"
    end
  end

  describe "import_directory/2" do
    import CashLens.AccountsFixtures

    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ingestor_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "imports all supported files from a directory", %{tmp_dir: tmp_dir} do
      account = account_fixture(parser_type: "bb_csv")
      File.cp!(@bb_sample, Path.join(tmp_dir, "sample.csv"))

      assert {:ok, %{imported: _}} = Ingestor.import_directory(account, tmp_dir)
    end

    test "returns error for a non-directory path" do
      account = account_fixture(parser_type: "bb_csv")

      assert {:error, "Path is not a directory"} =
               Ingestor.import_directory(account, "/nonexistent/path")
    end

    test "skips unsupported file types", %{tmp_dir: tmp_dir} do
      account = account_fixture(parser_type: "bb_csv")
      File.write!(Path.join(tmp_dir, "readme.txt"), "ignored")

      assert {:ok, %{imported: _}} = Ingestor.import_directory(account, tmp_dir)
    end

    test "returns error summary when files fail to import", %{tmp_dir: tmp_dir} do
      account = account_fixture(parser_type: "unknown_parser")
      File.write!(Path.join(tmp_dir, "file.csv"), "Data,Dep,Term,Hist,Doc,Valor,\n")

      assert {:error, msg} = Ingestor.import_directory(account, tmp_dir)
      assert msg =~ "files failed to import"
    end
  end
end
