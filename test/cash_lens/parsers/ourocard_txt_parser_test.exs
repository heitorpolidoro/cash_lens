defmodule CashLens.Parsers.OurocardTXTParserTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.OurocardTXTParser

  @sample """
                           Fatura do Cartão de Crédito
  Vencimento      : 16.07.2026
  Total da fatura : R$ 11.938,58

  Data     Transações                             País        Valor R$   Valor US$
  --------------------------------------------------------------------------------
           1 - HEITOR L POLIDORO

           SALDO FATURA ANTERIOR                  BR         14.391,19        0,00

           Pagamentos/Créditos
  16.06.2026PGTO DEBITO CONTA 5899 000009516  200211          -14.391,19        0,00

           Educação
  15.06.2026SCHOOL OF ROCK         SAO JOSE DOS  BR              537,82        0,00
  23.01.2026KIPLING       PARC 05/06 SAO JOSE DOSBR              183,16        0,00
           SubTotal                                           7.827,48        0,00
           Total                                             11.938,58        0,00
  """

  test "parses only dated lines, inverts sign, cleans description" do
    txns = OurocardTXTParser.parse(@sample, :ourocard)

    # 3 dated lines: the payment credit + 2 purchases. SALDO ANTERIOR/SubTotal/
    # Total/headers/labels have no leading date and are ignored.
    assert length(txns) == 3

    pay = Enum.find(txns, &(&1.date == ~D[2026-06-16]))
    assert pay.description == "PGTO DEBITO CONTA 5899 000009516 200211"
    assert Decimal.equal?(pay.amount, Decimal.new("14391.19"))

    rock = Enum.find(txns, &(&1.date == ~D[2026-06-15]))
    assert rock.description == "SCHOOL OF ROCK SAO JOSE DOS BR"
    assert Decimal.equal?(rock.amount, Decimal.new("-537.82"))

    kipling = Enum.find(txns, &String.contains?(&1.description, "KIPLING"))
    assert kipling.description == "KIPLING PARC 05/06 SAO JOSE DOSBR"
    assert Decimal.equal?(kipling.amount, Decimal.new("-183.16"))
    assert kipling.time == nil
  end

  test "returns [] when there are no dated lines" do
    assert OurocardTXTParser.parse(
             "Vencimento : 16.07.2026\nTotal da fatura : R$ 1,00",
             :ourocard
           ) == []
  end
end
