defmodule CashLens.Parsers.MercadoPagoPDFParserRealStatementsTest do
  @moduledoc """
  Opt-in corpus test over the operator's real Mercado Pago checking-account
  statements. Excluded unconditionally in `test/test_helper.exs`.

  It cannot run in the app container: `docker-compose.yml` deliberately does not
  bind-mount the Google Drive folder, because Drive placeholders cannot be
  materialised through a bind mount. Run it on the host, which needs the Postgres
  `polidoro-runner` publishes on 5432:

      # precondition: `./run` must be running (publishes Postgres on host port 5432)
      DATABASE_HOST=localhost DATABASE_PORT=5432 \\
        CASH_LENS_MP_PDF_DIR="<Drive folder>" \\
        mix test --include real_statements

  The folder path is never hard-coded: it is read from `CASH_LENS_MP_PDF_DIR`,
  and the test fails naming that variable rather than passing vacuously when it
  is unset.
  """
  # async: false — one test manipulates CASH_LENS_MP_PDF_DIR in the process
  # environment, which is global to the VM.
  use ExUnit.Case, async: false

  alias CashLens.Parsers.MercadoPagoPDFParser
  alias CashLens.Parsers.PDFConverter.SystemConverter

  @env_var "CASH_LENS_MP_PDF_DIR"

  # Measured over the whole corpus. Written as literals so a regression in the
  # segmentation rule shows up as a count, not as a silently different total.
  @expected_files 20
  @expected_transactions 407
  @expected_shapes %{{0, 0} => 381, {1, 1} => 22, {2, 2} => 4}
  @expected_inline_fragments 4
  @sample_file "pdf_260922100732.pdf"
  @sample_transactions 24
  @sample_multi_line 5

  @saldo_inicial_regex ~r/Saldo inicial:\s*R\$\s*(-?[\d.]+,\d{2})/u
  @saldo_final_regex ~r/Saldo final:\s*R\$\s*(-?[\d.]+,\d{2})/u

  defp statement_dir do
    case System.get_env(@env_var) do
      nil ->
        flunk(
          "#{@env_var} is not set. This test reads the operator's Mercado Pago " <>
            "statement folder and never hard-codes its path. Run it as: " <>
            "DATABASE_HOST=localhost DATABASE_PORT=5432 #{@env_var}=\"<Drive folder>\" " <>
            "mix test --include real_statements"
        )

      "" ->
        flunk("#{@env_var} is set but empty.")

      dir ->
        assert File.dir?(dir), "#{@env_var} points at #{dir}, which is not a directory"
        dir
    end
  end

  defp statement_texts do
    dir = statement_dir()

    texts =
      dir
      |> Path.join("*.pdf")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path ->
        assert {:ok, text} = SystemConverter.convert(path),
               "pdftotext could not read #{path}"

        {Path.basename(path), text}
      end)

    assert length(texts) == @expected_files
    texts
  end

  # (lines above, lines below) the block's transaction line.
  defp shape(block) do
    index =
      Enum.find_index(block, fn line ->
        Regex.match?(~r/^\s*\d{2}-\d{2}-\d{4}\s+.*\d{10,}\s+R\$/u, line)
      end)

    {index, length(block) - index - 1}
  end

  defp inline_fragment?(block) do
    block
    |> Enum.find(&Regex.match?(~r/^\s*\d{2}-\d{2}-\d{4}\s+.*\d{10,}\s+R\$/u, &1))
    |> then(&Regex.run(~r/^\s*\d{2}-\d{2}-\d{4}\s+(.*?)\s*\d{10,}\s+R\$/u, &1))
    |> case do
      [_, fragment] -> String.trim(fragment) != ""
      _ -> false
    end
  end

  defp to_decimal(brl) do
    brl |> String.replace(".", "") |> String.replace(",", ".") |> Decimal.new()
  end

  defp capture(text, regex) do
    assert [_, value] = Regex.run(regex, text)
    to_decimal(value)
  end

  @tag :real_statements
  test "parses every transaction in the corpus, with the measured shape distribution" do
    texts = statement_texts()

    blocks =
      Enum.flat_map(texts, fn {_name, text} -> MercadoPagoPDFParser.transaction_blocks(text) end)

    transactions =
      Enum.flat_map(texts, fn {_name, text} ->
        MercadoPagoPDFParser.parse(text, :mercado_pago_conta)
      end)

    assert length(transactions) == @expected_transactions
    assert length(blocks) == @expected_transactions

    assert Enum.frequencies_by(blocks, &shape/1) == @expected_shapes

    # A (0,0) row's description is inline by definition; the interesting case is
    # the (1,1) row that carries a fragment on the transaction line *as well as*
    # a line above and a line below.
    inline = Enum.filter(blocks, &(shape(&1) == {1, 1} and inline_fragment?(&1)))

    assert length(inline) == @expected_inline_fragments

    multi_line = Enum.reject(blocks, &(shape(&1) == {0, 0}))
    assert length(multi_line) == @expected_transactions - @expected_shapes[{0, 0}]
  end

  @tag :real_statements
  test "the Saldo chain reconciles to Saldo final in every file" do
    for {name, text} <- statement_texts() do
      initial = capture(text, @saldo_inicial_regex)
      final = capture(text, @saldo_final_regex)

      transactions = MercadoPagoPDFParser.parse(text, :mercado_pago_conta)

      # Re-read the printed Saldo column rather than hard-coding a ladder: this
      # test tracks files it does not own.
      printed =
        text
        |> MercadoPagoPDFParser.transaction_blocks()
        |> Enum.map(fn block ->
          [_, saldo] =
            block
            |> Enum.find(&Regex.match?(~r/R\$\s*-?[\d.]+,\d{2}\s*$/u, &1))
            |> then(&Regex.run(~r/R\$\s*(-?[\d.]+,\d{2})\s*$/u, &1))

          to_decimal(saldo)
        end)

      running =
        Enum.scan(transactions, initial, fn txn, acc -> Decimal.add(acc, txn.amount) end)

      assert length(running) == length(printed)

      for {computed, expected} <- Enum.zip(running, printed) do
        assert Decimal.equal?(computed, expected),
               "#{name}: running balance #{computed} does not match printed Saldo #{expected}"
      end

      assert Decimal.equal?(List.last(running) || initial, final),
             "#{name}: chain ends at #{List.last(running)}, Saldo final is #{final}"
    end
  end

  @tag :real_statements
  test "no block spans a page break" do
    for {name, text} <- statement_texts(),
        block <- MercadoPagoPDFParser.transaction_blocks(text) do
      page_opening =
        block
        |> Enum.with_index()
        |> Enum.filter(fn {line, _index} -> String.contains?(line, "\f") end)
        |> Enum.map(fn {_line, index} -> index end)

      assert page_opening in [[], [0]],
             "#{name}: a block carries a page break other than at its first line:\n" <>
               Enum.join(block, "\n")
    end
  end

  @tag :real_statements
  test "#{@sample_file} parses to its measured counts" do
    dir = statement_dir()
    assert {:ok, text} = SystemConverter.convert(Path.join(dir, @sample_file))

    transactions = MercadoPagoPDFParser.parse(text, :mercado_pago_conta)
    blocks = MercadoPagoPDFParser.transaction_blocks(text)

    assert length(transactions) == @sample_transactions
    assert Enum.count(blocks, &(shape(&1) != {0, 0})) == @sample_multi_line
  end

  @tag :real_statements
  test "fails with a message naming the environment variable when it is unset" do
    original = System.get_env(@env_var)
    System.delete_env(@env_var)
    on_exit(fn -> if original, do: System.put_env(@env_var, original) end)

    error = assert_raise ExUnit.AssertionError, fn -> statement_dir() end

    assert Exception.message(error) =~ @env_var
  end
end
