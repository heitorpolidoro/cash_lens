# Test script for format_currency function

defmodule CurrencyFormatTest do
  # Copy of the modified format_currency function
  def format_currency(value) do
    # Format with 2 decimal places
    formatted = :erlang.float_to_binary(abs(value), decimals: 2)

    # Split into integer and decimal parts
    [int_part, dec_part] = String.split(formatted, ".")

    # Add thousand separators to integer part
    int_with_separators =
      int_part
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.join(".")
      |> String.reverse()

    # Combine with comma as decimal separator
    "R$\u00A0#{int_with_separators},#{dec_part}"
  end

  def run_tests do
    test_cases = [
      {1234.56, "R$\u00A01.234,56"},
      {0.99, "R$\u00A00,99"},
      {1000000.00, "R$\u00A01.000.000,00"},
      {22321.43, "R$\u00A022.321,43"},
      {1.23, "R$\u00A01,23"}
    ]

    IO.puts("Running currency format tests:")

    Enum.each(test_cases, fn {input, expected} ->
      result = format_currency(input)
      if result == expected do
        IO.puts("✓ #{input} -> #{result}")
      else
        IO.puts("✗ #{input} -> #{result} (expected: #{expected})")
      end
    end)
  end
end

CurrencyFormatTest.run_tests()
