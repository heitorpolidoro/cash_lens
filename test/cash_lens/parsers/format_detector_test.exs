defmodule CashLens.Parsers.FormatDetectorTest do
  use ExUnit.Case, async: true

  alias CashLens.Parsers.AccountFile
  alias CashLens.Parsers.FormatDetector

  # Verbatim header of test/cash_lens/parsers/csv_parser_test.exs:181 (BOM included).
  @bradesco_header "﻿Data;Histórico;Docto.;Crédito (R$);Débito (R$);Saldo (R$)\n"

  # Verbatim body of test/cash_lens/parsers/csv_parser_test.exs:233 — note the
  # RELEASE_DATE header row is NOT the first row.
  @mercado_pago_csv """
  INITIAL_BALANCE;CREDITS;DEBITS;FINAL_BALANCE
  117,73;1,09;0,00;118,82

  RELEASE_DATE;TRANSACTION_TYPE;REFERENCE_ID;TRANSACTION_NET_AMOUNT;PARTIAL_BALANCE
  04-05-2026;Rendimentos ;1743175009624;0,05;117,78
  05-05-2026;Compra de 2 produtos Mercado Livre;101754796278;-48,51;69,27
  """

  # Verbatim @sample_ofx of test/cash_lens/parsers/ofx_parser_test.exs:5.
  @sample_ofx """
  <OFX>
  <STMTTRN>
  <TRNTYPE>DEBIT</TRNTYPE>
  <DTPOSTED>20260410120000</DTPOSTED>
  <TRNAMT>-150.00</TRNAMT>
  <MEMO>COMPRA SUPERMERCADO</MEMO>
  </STMTTRN>
  <STMTTRN>
  <TRNTYPE>CREDIT</TRNTYPE>
  <DTPOSTED>20260415103000</DTPOSTED>
  <TRNAMT>1200,50</TRNAMT>
  <NAME>TRANSFERENCIA RECEBIDA</NAME>
  </STMTTRN>
  </OFX>
  """

  # The repo carries no <CCSTMTTRN> sample, so this is @sample_ofx with the
  # transaction tag renamed, as the spec's test matrix prescribes.
  @credit_card_ofx String.replace(@sample_ofx, "STMTTRN", "CCSTMTTRN")

  # Verbatim @sample of test/cash_lens/parsers/ourocard_txt_parser_test.exs:5.
  @ourocard_txt """
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

  # Header-only body of ourocard_txt_parser_test.exs:49 (H_VENC true, L_TX false).
  @ourocard_header_only "Vencimento : 16.07.2026\nTotal da fatura : R$ 1,00"

  # Text lifted from test/cash_lens/parsers/pdf_parser_test.exs:8.
  @sem_parar_text """
  Extrato Mensal de Utilização
  Plano Contratado: SEM PARAR 10/12/25 R$ 58,17
  """

  # Text lifted from test/cash_lens/parsers/pdf_parser_test.exs:130.
  @bradesco_pdf_text """
  Fatura mensal
  HEITOR POLIDORO
  AMAZON MASTERCARD PLATINUM 5373.63**.****.8015

  Total da fatura                                                                Vencimento
  R$ 56,53                                                                       10/03/2026

  Lançamentos
  Data Descrição                                                        Valor R$
  28/01    AMAZON BR            SAO PAULO      BRA                           0,34
  Total da fatura em real                                                          56,53
  """

  # Text lifted from test/cash_lens/parsers/pdf_parser_test.exs:625 — the
  # collision case: it carries BOTH "Total a pagar" and "Total da fatura de
  # junho" (plus a "Lançamentos futuros" section).
  @mercado_pago_pdf_text """
  Olá, Heitor Luis
  Essa é sua fatura de julho
  Total a pagar                            Vence em                      Limite total
                                           17/07/2026                    R$ 23.200,00
  R$ 1.357,95

  Informações complementares
  Resumo da fatura

    Consumos de 13/06 a 12/07                               R$ 1.357,95

    Total da fatura de junho                                 R$ 1.412,10

                                                Total                    R$ 1.357,95

  Heitor Luis Polidoro
  Vencimento: 17/07/2026

  Lançamentos futuros

    Compras parceladas                            R$ 1.508,58

    Total                                        R$ 1.508,58
  """

  @bb_sample_path "test/support/fixtures/files/bb_sample.csv"

  describe "CSV detection" do
    test "bb_sample.csv fixture detects as bb_csv" do
      content = File.read!(@bb_sample_path)

      assert {:ok, verdict} = FormatDetector.detect(content)

      assert verdict.format == :csv
      assert verdict.parser_type == "bb_csv"

      assert verdict.account_hint == %{
               bank: "Banco do Brasil",
               credit_card: false,
               account_identifier: nil
             }
    end

    test "the BB Lançamento/Detalhes variant (no Dependência Origem) also detects as bb_csv" do
      content =
        "Data,Lançamento,Detalhes,N° documento,Valor,Tipo Lançamento\n" <>
          "24/02/2026,Pix - Enviado,JOAO DA SILVA,123456,-150.00,Saída\n"

      assert {:ok, %{format: :csv, parser_type: "bb_csv"}} = FormatDetector.detect(content)
    end

    test "the verbatim Bradesco header detects as bradesco_csv" do
      content = @bradesco_header <> "01/03/2026;COMPRA SUPERMERCADO;000123;;120,50;3.000,00\n"

      assert {:ok, verdict} = FormatDetector.detect(content)

      assert verdict.format == :csv
      assert verdict.parser_type == "bradesco_csv"

      assert verdict.account_hint == %{
               bank: "Bradesco",
               credit_card: false,
               account_identifier: nil
             }
    end

    test "a Mercado Pago body whose RELEASE_DATE row is not first detects as mercado_pago_csv" do
      assert {:ok, verdict} = FormatDetector.detect(@mercado_pago_csv)

      assert verdict.format == :csv
      assert verdict.parser_type == "mercado_pago_csv"

      assert verdict.account_hint == %{
               bank: "Mercado Pago",
               credit_card: false,
               account_identifier: nil
             }
    end

    test "a delimited but unknown CSV header is not guessed" do
      assert FormatDetector.detect("Foo;Bar;Baz\n1;2;3\n") == {:error, :unrecognized}
    end
  end

  describe "OFX detection" do
    test "the sample bank OFX detects as standard_ofx with credit_card false" do
      assert {:ok, verdict} = FormatDetector.detect(@sample_ofx)

      assert verdict.format == :ofx
      assert verdict.parser_type == "standard_ofx"

      assert verdict.account_hint == %{
               bank: nil,
               credit_card: false,
               account_identifier: nil
             }
    end

    test "a <CCSTMTTRN> body yields credit_card true and still standard_ofx" do
      assert {:ok, verdict} = FormatDetector.detect(@credit_card_ofx)

      assert verdict.format == :ofx
      assert verdict.parser_type == "standard_ofx"
      assert verdict.account_hint.credit_card == true
    end

    test "an OFXHEADER (1.x SGML) body is recognised" do
      content = "OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\n\n<STMTTRN>\n"

      assert {:ok, %{format: :ofx, parser_type: "standard_ofx"}} = FormatDetector.detect(content)
    end

    test "bank and account_identifier come from <ORG> and <ACCTID> when present" do
      content = """
      OFXHEADER:100
      <OFX>
      <ORG>Banco do Brasil S.A.</ORG>
      <FID>1</FID>
      <ACCTID>0001234567-8</ACCTID>
      <STMTTRN>
      <TRNAMT>-1.00</TRNAMT>
      </STMTTRN>
      </OFX>
      """

      assert {:ok, verdict} = FormatDetector.detect(content)

      assert verdict.parser_type == "standard_ofx"

      assert verdict.account_hint == %{
               bank: "Banco do Brasil S.A.",
               credit_card: false,
               account_identifier: "0001234567-8"
             }
    end

    test "never returns ourocard_ofx, even for a Banco do Brasil <ORG>" do
      content = "OFXHEADER:100\n<OFX><ORG>Banco do Brasil</ORG><BANKID>001</BANKID></OFX>"

      assert {:ok, %{parser_type: parser_type}} = FormatDetector.detect(content)
      refute parser_type == "ourocard_ofx"
      assert parser_type == "standard_ofx"
    end
  end

  describe "Ourocard TXT detection" do
    test "the full statement sample detects as ourocard_txt" do
      assert {:ok, verdict} = FormatDetector.detect(@ourocard_txt)

      assert verdict.format == :txt
      assert verdict.parser_type == "ourocard_txt"

      assert verdict.account_hint == %{
               bank: "Banco do Brasil",
               credit_card: true,
               account_identifier: nil
             }
    end

    test "a header-only body matches on H_VENC alone (no transaction lines)" do
      assert {:ok, %{format: :txt, parser_type: "ourocard_txt"}} =
               FormatDetector.detect(@ourocard_header_only)
    end

    test "transaction lines alone match on L_TX (no Vencimento header)" do
      content = "16.06.2026PGTO DEBITO CONTA 5899 000009516  200211          -14.391,19    0,00\n"

      assert {:ok, %{format: :txt, parser_type: "ourocard_txt"}} = FormatDetector.detect(content)
    end
  end

  describe "PDF detection" do
    test "a raw %PDF- binary with no :text yields format :pdf and no further inference" do
      content = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n"

      assert FormatDetector.detect(content) ==
               {:ok, %{format: :pdf, parser_type: nil, account_hint: nil}}
    end

    test "P1: text containing Plano Contratado detects as sem_parar_pdf" do
      assert {:ok, verdict} = FormatDetector.detect("", text: @sem_parar_text)

      assert verdict.format == :pdf
      assert verdict.parser_type == "sem_parar_pdf"

      assert verdict.account_hint == %{
               bank: "Sem Parar",
               credit_card: false,
               account_identifier: nil
             }
    end

    test "P2 wins over P3: a real Mercado Pago fatura text detects as mercadopago_cartao_pdf" do
      # This text also contains "Total da fatura de junho" and "Lançamentos
      # futuros", which a naive Bradesco probe would match.
      assert String.contains?(@mercado_pago_pdf_text, "Total da fatura de junho")
      assert String.contains?(@mercado_pago_pdf_text, "Lançamentos futuros")

      assert {:ok, verdict} = FormatDetector.detect("", text: @mercado_pago_pdf_text)

      assert verdict.format == :pdf
      assert verdict.parser_type == "mercadopago_cartao_pdf"

      assert verdict.account_hint == %{
               bank: "Mercado Pago",
               credit_card: true,
               account_identifier: nil
             }
    end

    test "P2 also matches on Movimentações na fatura" do
      text = "Fatura\nMovimentações na fatura\nCartão Visa\n"

      assert {:ok, %{parser_type: "mercadopago_cartao_pdf"}} =
               FormatDetector.detect("", text: text)
    end

    test "P3: a Bradesco fatura text still detects as bradesco_cartao_pdf" do
      assert {:ok, verdict} = FormatDetector.detect("", text: @bradesco_pdf_text)

      assert verdict.format == :pdf
      assert verdict.parser_type == "bradesco_cartao_pdf"

      assert verdict.account_hint == %{
               bank: "Bradesco",
               credit_card: true,
               account_identifier: nil
             }
    end

    test "P3 also matches on Bradesco Cartões" do
      text = "Aplicativo Bradesco Cartões\nData: 01/06/2026 - 08:46\n"

      assert {:ok, %{parser_type: "bradesco_cartao_pdf"}} = FormatDetector.detect("", text: text)
    end

    test "with :text supplied the format is :pdf even when content has no %PDF- magic" do
      content = "Data;Histórico;Docto.;Crédito (R$);Débito (R$);Saldo (R$)\n"

      assert {:ok, %{format: :pdf, parser_type: "sem_parar_pdf"}} =
               FormatDetector.detect(content, text: @sem_parar_text)
    end

    test "with :text supplied the format is :pdf even when content IS a %PDF- binary" do
      assert {:ok, %{format: :pdf, parser_type: "sem_parar_pdf"}} =
               FormatDetector.detect("%PDF-1.7\nbinary junk", text: @sem_parar_text)
    end

    test "PDF text matching no probe yields :pdf with nil parser_type and nil hint" do
      assert FormatDetector.detect("%PDF-1.4", text: "Some unrelated document text") ==
               {:ok, %{format: :pdf, parser_type: nil, account_hint: nil}}
    end

    test "a blank :text falls through to the remaining probes" do
      assert {:ok, %{format: :ofx}} = FormatDetector.detect(@sample_ofx, text: "   \n  ")
      assert {:ok, %{format: :ofx}} = FormatDetector.detect(@sample_ofx, text: nil)
    end
  end

  describe "content beats extension" do
    test "a CSV body with a .ofx filename is classified as CSV" do
      content = File.read!(@bb_sample_path)

      assert {:ok, %{format: :csv, parser_type: "bb_csv"}} =
               FormatDetector.detect(content, filename: "extrato.ofx")
    end

    test "an OFX body with a .csv filename is classified as OFX" do
      assert {:ok, %{format: :ofx, parser_type: "standard_ofx"}} =
               FormatDetector.detect(@sample_ofx, filename: "extrato.csv")
    end
  end

  describe "precedence" do
    test "an OFX body containing delimited lines is detected as :ofx, not :csv" do
      content =
        @sample_ofx <>
          "Data;Histórico;Docto.;Crédito (R$);Débito (R$);Saldo (R$)\n" <>
          "RELEASE_DATE;TRANSACTION_TYPE;REFERENCE_ID;TRANSACTION_NET_AMOUNT\n"

      assert {:ok, %{format: :ofx, parser_type: "standard_ofx"}} = FormatDetector.detect(content)
    end

    test "an Ourocard TXT body containing delimited lines is detected as :txt, not :csv" do
      content = @ourocard_header_only <> "\nData,Histórico,Valor\n"

      assert {:ok, %{format: :txt, parser_type: "ourocard_txt"}} = FormatDetector.detect(content)
    end
  end

  describe "unrecognised content" do
    test "empty content" do
      assert FormatDetector.detect("") == {:error, :unrecognized}
    end

    test "blank content" do
      assert FormatDetector.detect("   \n\n  ") == {:error, :unrecognized}
    end

    test "binary garbage does not raise" do
      assert FormatDetector.detect(<<0, 1, 2, 3, 255, 254, 127, 66, 99>>) ==
               {:error, :unrecognized}
    end

    test "latin-1 (invalid UTF-8) bytes do not raise" do
      # "Histórico;Saldo" encoded as latin-1: the ó is a bare 0xF3 byte.
      latin1 = <<72, 105, 115, 116, 0xF3, 114, 105, 99, 111, 59, 83, 97, 108, 100, 111>>

      assert FormatDetector.detect(latin1) == {:error, :unrecognized}
    end

    test "latin-1 bytes in a recognisable CSV are still classified" do
      latin1 = :unicode.characters_to_binary(File.read!(@bb_sample_path), :utf8, :latin1)

      assert {:ok, %{format: :csv, parser_type: "bb_csv"}} = FormatDetector.detect(latin1)
    end

    test "non-binary input" do
      assert FormatDetector.detect(nil) == {:error, :unrecognized}
    end
  end

  describe "output contract" do
    test "every parser_type the detector can return is a valid AccountFile parser" do
      inputs = [
        {File.read!(@bb_sample_path), []},
        {@bradesco_header, []},
        {@mercado_pago_csv, []},
        {@sample_ofx, []},
        {@credit_card_ofx, []},
        {@ourocard_txt, []},
        {@ourocard_header_only, []},
        {"%PDF-1.4", []},
        {"", [text: @sem_parar_text]},
        {"", [text: @mercado_pago_pdf_text]},
        {"", [text: @bradesco_pdf_text]}
      ]

      valid = AccountFile.valid_parsers()

      assert Enum.all?(FormatDetector.detectable_parsers(), &(&1 in valid))

      for {content, opts} <- inputs do
        assert {:ok, verdict} = FormatDetector.detect(content, opts)
        assert is_nil(verdict.parser_type) or verdict.parser_type in valid
        assert verdict.format in [:ofx, :csv, :pdf, :txt]
      end
    end

    test "detect/1 and detect/2 are both exported" do
      Code.ensure_loaded!(FormatDetector)
      assert function_exported?(FormatDetector, :detect, 1)
      assert function_exported?(FormatDetector, :detect, 2)
    end

    test "account_hint always carries the three documented keys" do
      assert {:ok, %{account_hint: hint}} = FormatDetector.detect(@ourocard_txt)
      assert Map.keys(hint) |> Enum.sort() == [:account_identifier, :bank, :credit_card]
    end
  end
end
