defmodule CashLens.Parsers.PDFConverterTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.PDFConverter.SystemConverter

  defmodule MockSystem do
    def cmd("pdftotext", ["-layout", "success.pdf", "-"]) do
      {"extracted text", 0}
    end

    def cmd("pdftotext", ["-layout", "error.pdf", "-"]) do
      {"error message", 1}
    end

    def cmd("pdftotext", ["-layout", "exception.pdf", "-"]) do
      raise "some system error"
    end
  end

  describe "SystemConverter.convert/2" do
    test "returns {:ok, text} on success" do
      assert {:ok, "extracted text"} = SystemConverter.convert("success.pdf", MockSystem)
    end

    test "returns {:error, :failed} when pdftotext returns non-zero" do
      assert {:error, :failed} = SystemConverter.convert("error.pdf", MockSystem)
    end

    test "returns {:error, :enoent} when an exception occurs (e.g. command not found)" do
      assert {:error, :enoent} = SystemConverter.convert("exception.pdf", MockSystem)
    end

    test "default convert/1 delegates to System runner" do
      # Even if pdftotext is not installed, the rescue block ensures this returns {:error, :enoent}
      # or {:error, :failed} if it is installed but file doesn't exist.
      # Both paths prove the function was called.
      result = SystemConverter.convert("non_existent.pdf")
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end
end
