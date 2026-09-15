defmodule CashLens.Transactions.AmountInputTest do
  use ExUnit.Case, async: true

  alias CashLens.Transactions.AmountInput

  describe "parse/1" do
    test "parses a plain integer as a positive (income) amount" do
      assert {:ok, decimal} = AmountInput.parse("50")
      assert Decimal.equal?(decimal, Decimal.new("50"))
    end

    test "keeps an explicit plus sign positive" do
      assert {:ok, decimal} = AmountInput.parse("+50")
      assert Decimal.equal?(decimal, Decimal.new("50"))
    end

    test "parses a leading minus sign as a negative (expense) amount" do
      assert {:ok, decimal} = AmountInput.parse("-80,00")
      assert Decimal.equal?(decimal, Decimal.new("-80.00"))
    end

    test "parses the Brazilian grouped format with a sign" do
      assert {:ok, decimal} = AmountInput.parse("-1.234,56")
      assert Decimal.equal?(decimal, Decimal.new("-1234.56"))
    end

    test "parses a comma decimal separator without grouping" do
      assert {:ok, decimal} = AmountInput.parse("1234,56")
      assert Decimal.equal?(decimal, Decimal.new("1234.56"))
    end

    test "parses a dot decimal separator (US style) unchanged" do
      assert {:ok, decimal} = AmountInput.parse("1234.56")
      assert Decimal.equal?(decimal, Decimal.new("1234.56"))
    end

    test "treats dots as thousand separators when they group three digits" do
      assert {:ok, decimal} = AmountInput.parse("1.234")
      assert Decimal.equal?(decimal, Decimal.new("1234"))
    end

    test "ignores a currency prefix and surrounding whitespace" do
      assert {:ok, decimal} = AmountInput.parse("  R$ -2.500,00 ")
      assert Decimal.equal?(decimal, Decimal.new("-2500.00"))
    end

    test "accepts a decimal struct unchanged" do
      assert {:ok, decimal} = AmountInput.parse(Decimal.new("-12.30"))
      assert Decimal.equal?(decimal, Decimal.new("-12.30"))
    end

    test "returns :empty for blank input" do
      assert AmountInput.parse("") == :empty
      assert AmountInput.parse("   ") == :empty
      assert AmountInput.parse(nil) == :empty
    end

    test "accepts the numeric types Ecto and Jason can hand over" do
      assert {:ok, from_integer} = AmountInput.parse(-50)
      assert Decimal.equal?(from_integer, Decimal.new("-50"))

      assert {:ok, from_float} = AmountInput.parse(12.5)
      assert Decimal.equal?(from_float, Decimal.new("12.5"))
    end

    test "rejects a value that is not a number at all" do
      assert AmountInput.parse(%{}) == :error
      assert AmountInput.parse([1, 2]) == :error
      assert AmountInput.parse(:atom) == :error
    end

    test "persists exactly what the QA table pins for every accepted format" do
      cases = [
        {"-1.234,56", "-1234.56"},
        {"1234,56", "1234.56"},
        {"+50", "50"},
        {"1.234", "1234"}
      ]

      for {typed, expected} <- cases do
        assert {:ok, decimal} = AmountInput.parse(typed), "expected #{inspect(typed)} to parse"

        assert Decimal.equal?(decimal, Decimal.new(expected)),
               "expected #{inspect(typed)} to persist #{expected}, got #{Decimal.to_string(decimal)}"
      end

      for typed <- [",50", "abc", ""] do
        assert AmountInput.parse(typed) in [:error, :empty],
               "expected #{inspect(typed)} to be rejected"
      end
    end

    test "rejects mixed separators instead of silently coercing them" do
      # "1,234.56" used to persist 1.23456 (1000x off) and "1.23,45" used to
      # persist 123.45. A comma means the dots before it must group thousands.
      for typed <- ["1,234.56", "1.23,45", "-1,234.56", "12.3.456,78", "1.2345,67"] do
        assert AmountInput.parse(typed) == :error,
               "expected #{inspect(typed)} to be rejected, got #{inspect(AmountInput.parse(typed))}"
      end
    end

    test "rejects garbage without crashing" do
      for garbage <- ["abc", "--5", "1,2,3", "-", "+", "1.2.3,4,5", "12a", "1..2"] do
        assert AmountInput.parse(garbage) == :error, "expected #{inspect(garbage)} to be rejected"
      end
    end
  end

  describe "kind/1" do
    test "classifies a leading minus as an expense" do
      assert AmountInput.kind("-10") == :expense
      assert AmountInput.kind(" -1.234,56") == :expense
      assert AmountInput.kind(Decimal.new("-1")) == :expense
    end

    test "classifies unsigned and plus-signed input as income" do
      assert AmountInput.kind("10") == :income
      assert AmountInput.kind("+10") == :income
      assert AmountInput.kind(Decimal.new("1")) == :income
    end

    test "classifies blank input as neutral" do
      assert AmountInput.kind("") == :neutral
      assert AmountInput.kind(nil) == :neutral
    end

    test "classifies non-string numeric input through its parsed value" do
      assert AmountInput.kind(-50) == :expense
      assert AmountInput.kind(12.5) == :income
      assert AmountInput.kind(%{}) == :neutral
    end
  end

  describe "to_input_value/1" do
    test "renders a stored decimal in the Brazilian format the field accepts back" do
      assert AmountInput.to_input_value(Decimal.new("-1234.56")) == "-1.234,56"
      assert AmountInput.to_input_value(Decimal.new("2500")) == "2.500,00"
    end

    test "renders blank for a missing amount" do
      assert AmountInput.to_input_value(nil) == ""
      assert AmountInput.to_input_value("") == ""
    end

    test "normalises a value that arrives as a string instead of a decimal" do
      assert AmountInput.to_input_value("-1234.56") == "-1.234,56"
      # Unparseable input is echoed back so the user still sees what they typed.
      assert AmountInput.to_input_value("abc") == "abc"
    end

    test "round-trips through parse/1 without flipping the sign" do
      for original <- ["-1234.56", "2500.00", "-0.99", "1000000.01"] do
        decimal = Decimal.new(original)

        assert {:ok, parsed} = decimal |> AmountInput.to_input_value() |> AmountInput.parse()
        assert Decimal.equal?(parsed, decimal)
      end
    end
  end
end
