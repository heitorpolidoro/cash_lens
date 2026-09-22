defmodule CashLens.Parsers.MercadoPagoPDFParserTest do
  use ExUnit.Case, async: true

  alias CashLens.Parsers.MercadoPagoPDFParser

  @fixtures Path.expand("../../support/fixtures/files", __DIR__)

  # Every operation id that appears in a committed fixture. No parsed description
  # may contain any of them: the id is used only to locate the amount columns and
  # is never carried into the return value.
  @operation_ids ~w(
    1726751323194 1726793381608 101754796278 105896764502 103603093883
    108252319490 143869767019 1744987253001 1745098621182 163576192336
    1745210993004 1736042118773 1736099749158 1736155503335 1736214781881
  )

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp parse(name), do: MercadoPagoPDFParser.parse(fixture(name), :mercado_pago_conta)

  defp descriptions(transactions), do: Enum.map(transactions, & &1.description)

  defp amounts(transactions), do: Enum.map(transactions, &Decimal.to_string(&1.amount, :normal))

  # Saldo inicial plus the running sum of parsed amounts, as strings, so the
  # expected ladder can be written as the literal column the statement prints.
  defp balance_ladder(transactions, initial) do
    transactions
    |> Enum.scan(Decimal.new(initial), fn txn, acc -> Decimal.add(acc, txn.amount) end)
    |> Enum.map(&Decimal.to_string(&1, :normal))
  end

  describe "behaviour contract" do
    test "declares the Parser behaviour" do
      assert CashLens.Parsers.Parser in MercadoPagoPDFParser.module_info(:attributes)[:behaviour]
    end

    test "returns maps whose key set is exactly the four Parser.transaction_map keys" do
      transactions = parse("mercado_pago_extrato_shapes.txt")

      assert transactions != []

      for txn <- transactions do
        assert txn |> Map.keys() |> Enum.sort() == [:amount, :date, :description, :time]
        assert txn.time == nil
        assert %Date{} = txn.date
        assert %Decimal{} = txn.amount
        assert is_binary(txn.description)
      end
    end
  end

  describe "date and amount parsing" do
    setup do
      {:ok, transactions: parse("mercado_pago_extrato_shapes.txt")}
    end

    test "reads the hyphenated dd-mm-yyyy date", %{transactions: transactions} do
      dates = Enum.map(transactions, & &1.date)

      assert dates == [
               ~D[2025-02-05],
               ~D[2025-02-06],
               ~D[2025-02-08],
               ~D[2025-03-21],
               ~D[2025-03-25],
               ~D[2025-04-12],
               ~D[2026-02-02]
             ]
    end

    test "takes the sign from after the R$ and treats . as a thousands separator", %{
      transactions: transactions
    } do
      assert amounts(transactions) == [
               "0.06",
               "0.09",
               "-48.51",
               "-186.62",
               "1099.00",
               "-42.99",
               "-20.00"
             ]
    end

    test "08-02-2025 / R$ -48,51 parses to ~D[2025-02-08] and Decimal -48.51", %{
      transactions: transactions
    } do
      txn = Enum.at(transactions, 2)

      assert txn.date == ~D[2025-02-08]
      assert Decimal.equal?(txn.amount, Decimal.new("-48.51"))
    end

    test "R$ 1.099,00 parses to Decimal 1099.00", %{transactions: transactions} do
      assert Decimal.equal?(Enum.at(transactions, 4).amount, Decimal.new("1099.00"))
    end
  end

  describe "description reassembly" do
    setup do
      {:ok, transactions: parse("mercado_pago_extrato_shapes.txt")}
    end

    test "the (0,0) Rendimentos shape absorbs no neighbouring line", %{
      transactions: transactions
    } do
      assert Enum.at(transactions, 0).description == "Rendimentos"
      assert Enum.at(transactions, 1).description == "Rendimentos"
    end

    test "a (1,1) shape joins the line above and the line below", %{transactions: transactions} do
      assert Enum.at(transactions, 2).description == "Compra de 2 produtos Mercado Livre"
    end

    test "a (2,2) shape joins both lines above and both below, top to bottom", %{
      transactions: transactions
    } do
      assert Enum.at(transactions, 3).description ==
               "Compra de Soprador De Ar Pó Potente Computador Notebook 110v/220v Mercado Livre"
    end

    test "an inline fragment is placed between the lines above and the lines below", %{
      transactions: transactions
    } do
      assert Enum.at(transactions, 5).description ==
               "Compra de Multímetro Digital Automotivo C/ Iluminação Bip Profissional Bekcommerce..."
    end

    test "a continuation line repeating the identity header survives intact", %{
      transactions: transactions
    } do
      txn = Enum.at(transactions, 6)

      assert txn.date == ~D[2026-02-02]
      assert Decimal.equal?(txn.amount, Decimal.new("-20.00"))
      assert txn.description == "Transferência Pix enviada Heitor Luis Polidoro"
    end
  end

  describe "positional noise stripping" do
    test "no description carries an operation id, a column header, a page marker or footer text" do
      transactions =
        Enum.flat_map(
          [
            "mercado_pago_extrato_shapes.txt",
            "mercado_pago_extrato_two_pages.txt",
            "mercado_pago_extrato_two_pages_no_header.txt",
            "mercado_pago_extrato_shared_operation_id.txt"
          ],
          &parse/1
        )

      for description <- descriptions(transactions) do
        for id <- @operation_ids do
          refute String.contains?(description, id)
        end

        refute String.contains?(description, "ID da operação")
        refute String.contains?(description, "Data de geração")
        refute String.contains?(description, "EXTRATO DE CONTA")
        refute String.contains?(description, "Saldo inicial")
        refute String.contains?(description, "Saldo final")
        refute String.contains?(description, "DETALHE DOS MOVIMENTOS")
        refute String.contains?(description, "CPF/CNPJ")
        refute String.contains?(description, "Periodo:")
        refute String.contains?(description, "Mercado Pago Instituição de Pagamento")
        refute description =~ ~r{\b\d+/\d+\b}
      end
    end

    test "no noise line produces a transaction of its own" do
      transactions = parse("mercado_pago_extrato_two_pages.txt")

      assert length(transactions) == 4
    end

    test "a description reading Pix enviado Heitor Luis / Polidoro survives content collision" do
      # The account holder's name is both the identity header line and part of this
      # description, so it survives only if noise is stripped by position.
      transactions = parse("mercado_pago_extrato_two_pages.txt")

      assert Enum.at(transactions, 2).description == "Pix enviado Heitor Luis Polidoro"
    end
  end

  describe "page breaks" do
    test "returns every transaction from both pages when the page-2 header is repeated" do
      transactions = parse("mercado_pago_extrato_two_pages.txt")

      assert Enum.map(transactions, & &1.date) == [
               ~D[2026-06-02],
               ~D[2026-06-05],
               ~D[2026-06-11],
               ~D[2026-06-12]
             ]

      assert descriptions(transactions) == [
               "Rendimentos",
               "Rendimentos",
               "Pix enviado Heitor Luis Polidoro",
               "Rendimentos"
             ]
    end

    test "returns every transaction when the page-2 header is absent" do
      transactions = parse("mercado_pago_extrato_two_pages_no_header.txt")

      assert Enum.map(transactions, & &1.date) == [
               ~D[2025-11-12],
               ~D[2025-11-13],
               ~D[2025-11-14],
               ~D[2025-11-17]
             ]
    end

    test "keeps the transaction the form feed is prefixed to" do
      # In this layout the form feed is glued to a transaction line and the 1/2
      # page marker is its immediate neighbour. Dropping lines that contain \f, or
      # blank-splitting before the marker is removed, loses this R$ 0,04 row.
      transactions = parse("mercado_pago_extrato_two_pages_no_header.txt")
      txn = Enum.at(transactions, 2)

      assert txn.date == ~D[2025-11-14]
      assert txn.description == "Rendimentos"
      assert Decimal.equal?(txn.amount, Decimal.new("0.04"))
    end
  end

  describe "unrecognised content" do
    test "raises with the offending text when a surviving block holds no transaction line" do
      assert_raise RuntimeError, fn ->
        parse("mercado_pago_extrato_orphan_block.txt")
      end

      message =
        try do
          parse("mercado_pago_extrato_orphan_block.txt")
          nil
        rescue
          error -> Exception.message(error)
        end

      assert message =~ "Aviso importante sobre a sua conta"
      assert message =~ "sem linha de movimento"
    end

    test "raises when a block holds more than one transaction line" do
      text = """
                                            DETALHE DOS MOVIMENTOS

      05-02-2025    Rendimentos                  1726751323194                  R$ 0,06            R$ 245,01
      06-02-2025    Rendimentos                  1726793381608                  R$ 0,09            R$ 245,10

      Data de geração: 15-06-2026
      """

      assert_raise RuntimeError, ~r/1726751323194/, fn ->
        MercadoPagoPDFParser.parse(text, :mercado_pago_conta)
      end
    end
  end

  describe "balance reconciliation over committed fixtures" do
    test "mercado_pago_extrato_shapes.txt chains Saldo inicial to Saldo final" do
      transactions = parse("mercado_pago_extrato_shapes.txt")

      assert balance_ladder(transactions, "244.95") == [
               "245.01",
               "245.10",
               "196.59",
               "9.97",
               "1108.97",
               "1065.98",
               "1045.98"
             ]
    end

    test "mercado_pago_extrato_two_pages.txt chains Saldo inicial to Saldo final" do
      transactions = parse("mercado_pago_extrato_two_pages.txt")

      assert balance_ladder(transactions, "32.15") == ["32.17", "32.20", "0.00", "0.01"]
    end

    test "mercado_pago_extrato_two_pages_no_header.txt chains Saldo inicial to Saldo final" do
      transactions = parse("mercado_pago_extrato_two_pages_no_header.txt")

      assert balance_ladder(transactions, "97.88") == ["97.93", "97.98", "98.02", "98.07"]
    end

    test "mercado_pago_extrato_shared_operation_id.txt chains Saldo inicial to Saldo final" do
      transactions = parse("mercado_pago_extrato_shared_operation_id.txt")

      assert balance_ladder(transactions, "244.95") == ["196.44", "215.07"]
    end
  end
end
