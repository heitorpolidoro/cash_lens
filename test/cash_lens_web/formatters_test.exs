defmodule CashLensWeb.FormattersTest do
  use CashLensWeb.ConnCase, async: true
  alias CashLensWeb.Formatters

  describe "format_currency/1" do
    test "formats nil as zero" do
      assert Formatters.format_currency(nil) == "R$ 0,00"
    end

    test "formats positive amounts" do
      assert Formatters.format_currency(1234.56) == "R$ 1.234,56"
      assert Formatters.format_currency(Decimal.new("1000")) == "R$ 1.000,00"
      assert Formatters.format_currency(5.5) == "R$ 5,50"
    end

    test "formats negative amounts" do
      assert Formatters.format_currency(-1234.56) == "R$ -1.234,56"
      assert Formatters.format_currency(Decimal.new("-50.5")) == "R$ -50,50"
    end
  end

  describe "format_date/1" do
    test "formats nil as empty string" do
      assert Formatters.format_date(nil) == ""
    end

    test "formats Date struct" do
      date = ~D[2026-04-23]
      assert Formatters.format_date(date) == "23/04/2026"
    end

    test "formats ISO8601 string" do
      assert Formatters.format_date("2026-04-23") == "23/04/2026"
    end

    test "returns original string for invalid ISO8601" do
      assert Formatters.format_date("invalid") == "invalid"
    end
  end

  describe "format_time/1" do
    test "formats nil as empty string" do
      assert Formatters.format_time(nil) == ""
    end

    test "formats Time struct" do
      time = ~T[14:30:00]
      assert Formatters.format_time(time) == "14:30"
    end
  end

  describe "format_weekday/1" do
    test "returns abbreviated weekday in Portuguese" do
      assert Formatters.format_weekday(~D[2026-04-20]) == "seg"
      assert Formatters.format_weekday(~D[2026-04-21]) == "ter"
      assert Formatters.format_weekday(~D[2026-04-22]) == "qua"
      assert Formatters.format_weekday(~D[2026-04-23]) == "qui"
      assert Formatters.format_weekday(~D[2026-04-24]) == "sex"
      assert Formatters.format_weekday(~D[2026-04-25]) == "sab"
      assert Formatters.format_weekday(~D[2026-04-26]) == "dom"
    end
  end

  describe "translate_reimbursement_status/2" do
    test "returns empty string for nil status" do
      assert Formatters.translate_reimbursement_status(nil, 100) == ""
    end

    test "translates pending and requested" do
      assert Formatters.translate_reimbursement_status("pending", 100) == "Pendente"
      assert Formatters.translate_reimbursement_status("requested", 100) == "Solicitado"
    end

    test "translates paid based on amount" do
      assert Formatters.translate_reimbursement_status("paid", Decimal.new("-50")) ==
               "Reembolso Pago"

      assert Formatters.translate_reimbursement_status("paid", Decimal.new("50")) == "Reembolso"
    end

    test "capitalizes other statuses" do
      assert Formatters.translate_reimbursement_status("other", 100) == "Other"
    end
  end

  describe "translate_parser_type/1" do
    test "translates known parser types" do
      assert Formatters.translate_parser_type("bb_csv") == "Banco do Brasil (CSV)"
      assert Formatters.translate_parser_type("sem_parar_pdf") == "Sem Parar (PDF)"
    end

    test "returns default for unknown types" do
      assert Formatters.translate_parser_type("unknown") == "Não configurado"
      assert Formatters.translate_parser_type(nil) == "Não configurado"
    end
  end
end
