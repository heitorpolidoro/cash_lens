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

    test "dispatches to bradesco_csv parser" do
      content =
        "﻿Data;Histórico;Docto.;Crédito (R$);Débito (R$);Saldo (R$)\n" <>
          "01/03/2026;COMPRA;000;;120,50;3.000,00\n"

      [tx] = Ingestor.parse(content, "bradesco_csv")
      assert tx.description == "COMPRA"
      assert tx.amount == Decimal.new("-120.50")
    end

    test "dispatches to ourocard_ofx parser" do
      content =
        "<STMTTRN><TRNTYPE>PAYMENT</TRNTYPE><DTPOSTED>20260415</DTPOSTED>" <>
          "<TRNAMT>-66.00</TRNAMT><MEMO>VALE EVENTOS   SAO PAULO  BR</MEMO></STMTTRN>"

      [tx] = Ingestor.parse(content, "ourocard_ofx")
      assert tx.description == "VALE EVENTOS SAO PAULO BR"
      assert tx.amount == Decimal.new("-66.00")
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

    test "does not import transactions dated in the future" do
      account = account_fixture(parser_type: "bb_csv")
      file_path = "test/support/fixtures/files/future_#{account.id}.csv"
      future = Date.utc_today() |> Date.add(60) |> Calendar.strftime("%d/%m/%Y")

      content =
        "Data,Dep,Term,Hist,Doc,Valor,\n" <>
          "01/01/2026,0,0,COMPRA PASSADA,1,-100.00,\n" <>
          "#{future},0,0,COMPRA FUTURA,1,-50.00,\n"

      File.write!(file_path, content)
      assert {:ok, %{imported: 1}} = Ingestor.import_file(account, file_path)
      File.rm!(file_path)

      descriptions =
        CashLens.Repo.all(CashLens.Transactions.Transaction) |> Enum.map(& &1.description)

      assert "COMPRA PASSADA" in descriptions
      refute "COMPRA FUTURA" in descriptions
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

    test "quarantines rows that crash during entry preparation" do
      defmodule CrashingCategorizer do
        def categorize(_), do: raise("simulated crash")
      end

      Application.put_env(:cash_lens, :auto_categorizer, CrashingCategorizer)
      on_exit(fn -> Application.delete_env(:cash_lens, :auto_categorizer) end)

      account = account_fixture(parser_type: "bb_csv")
      assert {:ok, %{imported: 0, failed: failed}} = Ingestor.import_file(account, @bb_sample)
      assert length(failed) == 3
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

  describe "duplicate-safe re-import" do
    import CashLens.AccountsFixtures
    alias CashLens.Transactions.Transaction

    test "importing the same OFX fatura twice yields no duplicates and reports skips" do
      account = account_fixture(parser_type: "ourocard_ofx")

      ofx = """
      <STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260415</DTPOSTED>
      <TRNAMT>-66.00</TRNAMT><MEMO>VALE EVENTOS   SAO PAULO  BR</MEMO></STMTTRN>
      <STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260416</DTPOSTED>
      <TRNAMT>-12.50</TRNAMT><MEMO>PADARIA SAO JOSE</MEMO></STMTTRN>
      """

      file_path = "test/support/fixtures/files/fatura_#{account.id}.ofx"
      File.write!(file_path, ofx)
      on_exit(fn -> File.rm(file_path) end)

      assert {:ok, %{imported: 2, skipped: 0}} = Ingestor.import_file(account, file_path)
      assert {:ok, %{imported: 0, skipped: 2}} = Ingestor.import_file(account, file_path)

      assert Repo.aggregate(Transaction, :count) == 2
    end

    test "date-only re-import with amount-scale drift still dedupes" do
      account = account_fixture(parser_type: "ourocard_ofx")

      # Both runs are a credit-style date-only DTPOSTED (no time): the stable
      # 00:00:00 default makes them share a base key. Amount scale drifts
      # (-66.00 vs -66.0) but integer-cents canonicalization keeps the key
      # identical -> re-import dedupes. This is the original duplication
      # root-cause scenario, now fixed by the stable time default.
      first = """
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-66.00</TRNAMT>\
      <MEMO>VALE EVENTOS SAO PAULO BR</MEMO></STMTTRN>
      """

      second = """
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-66.0</TRNAMT>\
      <MEMO>VALE EVENTOS SAO PAULO BR</MEMO></STMTTRN>
      """

      p1 = "test/support/fixtures/files/drift1_#{account.id}.ofx"
      p2 = "test/support/fixtures/files/drift2_#{account.id}.ofx"
      File.write!(p1, first)
      File.write!(p2, second)
      on_exit(fn -> File.rm(p1) && File.rm(p2) end)

      assert {:ok, %{imported: 1, skipped: 0}} = Ingestor.import_file(account, p1)
      assert {:ok, %{imported: 0, skipped: 1}} = Ingestor.import_file(account, p2)

      assert Repo.aggregate(Transaction, :count) == 1
    end

    test "two genuinely identical same-day charges are both preserved (occurrence index)" do
      account = account_fixture(parser_type: "ourocard_ofx")

      # Two identical lines in one fatura: same date, amount and merchant. These
      # are distinct real purchases and must BOTH be kept (indices 0 and 1).
      ofx = """
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-48.00</TRNAMT>\
      <MEMO>JULIO CESAR DE SAO JOSE</MEMO></STMTTRN>
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-48.00</TRNAMT>\
      <MEMO>JULIO CESAR DE SAO JOSE</MEMO></STMTTRN>
      """

      path = "test/support/fixtures/files/twins_#{account.id}.ofx"
      File.write!(path, ofx)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{imported: 2, skipped: 0}} = Ingestor.import_file(account, path)
      assert Repo.aggregate(Transaction, :count) == 2

      # Re-importing the exact same fatura reproduces indices 0 and 1, so BOTH
      # collide with the stored rows: zero new rows, both reported skipped.
      assert {:ok, %{imported: 0, skipped: 2}} = Ingestor.import_file(account, path)
      assert Repo.aggregate(Transaction, :count) == 2
    end

    test "two identical same-day credit à-vista charges are both preserved" do
      account = account_fixture(parser_type: "ourocard_ofx")

      # Credit (à-vista) OFX postings are date-only, so both lines normalize to
      # the stable time 00:00:00 -> identical base key. They are distinct real
      # purchases and must BOTH survive via occurrence indices 0 and 1.
      ofx = """
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-79.90</TRNAMT>\
      <MEMO>LIVRARIA CULTURA SP</MEMO></STMTTRN>
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-79.90</TRNAMT>\
      <MEMO>LIVRARIA CULTURA SP</MEMO></STMTTRN>
      """

      path = "test/support/fixtures/files/credit_twins_#{account.id}.ofx"
      File.write!(path, ofx)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{imported: 2, skipped: 0}} = Ingestor.import_file(account, path)
      assert Repo.aggregate(Transaction, :count) == 2

      # Re-importing the exact same fatura reproduces times (00:00:00) AND
      # ordinals (0, 1), so both collide: zero duplicates.
      assert {:ok, %{imported: 0, skipped: 2}} = Ingestor.import_file(account, path)
      assert Repo.aggregate(Transaction, :count) == 2
    end

    test "same-day same-amount debit charges at distinct times are both preserved" do
      account = account_fixture(parser_type: "ourocard_ofx")

      # Two debit charges with REAL distinct times get distinct base keys via the
      # time discriminator (each at occurrence index 0) and are both preserved.
      ofx = """
      <STMTTRN><DTPOSTED>20260415083000</DTPOSTED><TRNAMT>-15.00</TRNAMT>\
      <MEMO>METRO SP</MEMO></STMTTRN>
      <STMTTRN><DTPOSTED>20260415173000</DTPOSTED><TRNAMT>-15.00</TRNAMT>\
      <MEMO>METRO SP</MEMO></STMTTRN>
      """

      path = "test/support/fixtures/files/debit_times_#{account.id}.ofx"
      File.write!(path, ofx)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{imported: 2, skipped: 0}} = Ingestor.import_file(account, path)
      assert Repo.aggregate(Transaction, :count) == 2

      # Re-import reproduces the same times -> same fingerprints -> zero dups.
      assert {:ok, %{imported: 0, skipped: 2}} = Ingestor.import_file(account, path)
      assert Repo.aggregate(Transaction, :count) == 2
    end

    test "occurrence index accounts for rows already stored across separate imports" do
      account = account_fixture(parser_type: "ourocard_ofx")

      one = """
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-10.00</TRNAMT>\
      <MEMO>CAFE</MEMO></STMTTRN>
      """

      two = """
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-10.00</TRNAMT>\
      <MEMO>CAFE</MEMO></STMTTRN>
      <STMTTRN><DTPOSTED>20260415</DTPOSTED><TRNAMT>-10.00</TRNAMT>\
      <MEMO>CAFE</MEMO></STMTTRN>
      """

      p1 = "test/support/fixtures/files/seq1_#{account.id}.ofx"
      p2 = "test/support/fixtures/files/seq2_#{account.id}.ofx"
      File.write!(p1, one)
      File.write!(p2, two)
      on_exit(fn -> File.rm(p1) && File.rm(p2) end)

      # First import stores one row at index 0.
      assert {:ok, %{imported: 1, skipped: 0}} = Ingestor.import_file(account, p1)

      # Second import has two identical lines: the first matches the stored index
      # 0 (skipped), the second takes index 1 (a genuine new repeat, inserted).
      assert {:ok, %{imported: 1, skipped: 1}} = Ingestor.import_file(account, p2)
      assert Repo.aggregate(Transaction, :count) == 2
    end
  end

  describe "expected_extensions/1" do
    test "maps csv parsers to .csv" do
      assert Ingestor.expected_extensions("bradesco_csv") == [".csv"]
      assert Ingestor.expected_extensions("bb_csv") == [".csv"]
    end

    test "maps ofx parsers to .ofx" do
      assert Ingestor.expected_extensions("ourocard_ofx") == [".ofx"]
      assert Ingestor.expected_extensions("standard_ofx") == [".ofx"]
    end

    test "maps pdf parser to .pdf" do
      assert Ingestor.expected_extensions("sem_parar_pdf") == [".pdf"]
    end

    test "returns empty list for unknown parser" do
      assert Ingestor.expected_extensions("unknown") == []
      assert Ingestor.expected_extensions(nil) == []
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
