defmodule CashLens.Transactions.InstallmentDetectorTest do
  use ExUnit.Case, async: true

  alias CashLens.Transactions.InstallmentDetector

  describe "detect/1" do
    test "parses a standard 'PARC X/Y' purchase and strips location" do
      assert %{base: "CAPRICHO VEIC", number: 2, total: 6} =
               InstallmentDetector.detect("CAPRICHO VEIC PARC 02/06 SAO JOSE DOSBR")
    end

    test "parses a hyphen-attached 'TIT-PARC' annuity entry" do
      assert %{base: "ANUIDADE DIFERENCIADA TIT", number: 1, total: 12} =
               InstallmentDetector.detect("ANUIDADE DIFERENCIADA TIT-PARC 01/12 BR")
    end

    test "keeps a leading store code in the base" do
      assert %{base: "00030 SH CEN", number: 1, total: 2} =
               InstallmentDetector.detect("00030 SH CEN PARC 01/02 SAO JOSE DOSBR")
    end

    test "returns nil when there is no installment marker" do
      assert InstallmentDetector.detect("SCHOOL OF ROCK SAO JOSE DOS BR") == nil
    end

    test "returns nil for nil/empty" do
      assert InstallmentDetector.detect(nil) == nil
      assert InstallmentDetector.detect("") == nil
    end

    test "returns nil for non-binary input" do
      assert InstallmentDetector.detect(123) == nil
      assert InstallmentDetector.detect(%{}) == nil
    end

    test "ignores a single-installment marker (X/1 is not really a plan)" do
      assert InstallmentDetector.detect("LOJA QUALQUER PARC 01/01 BR") == nil
    end
  end
end
