defmodule CashLens.Helper do
  @moduledoc false

  def format_atom_title(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  def format_atom_title(string) when is_binary(string) do
    string
    |> String.to_atom()
    |> format_atom_title()
  end

  @doc """
  Formats a numeric value as Brazilian currency (R$ non-breaking space, dot for thousands, comma for decimals).
  Accepts Decimal, integer, or float. Uses absolute value (sign can be indicated via styling elsewhere).
  Examples:
    iex> CashLens.Helper.format_currency(1234.5)
    "R$\u00A01.234,50"
  """
  def format_currency(value) do
    float_value =
      cond do
        is_integer(value) ->
          value / 1.0

        is_float(value) ->
          value

        Code.ensure_loaded?(Decimal) and match?(%Decimal{}, value) ->
          Decimal.to_float(value)

        true ->
          raise ArgumentError, "Unsupported value for format_currency: #{inspect(value)}"
      end

    formatted = :erlang.float_to_binary(abs(float_value), decimals: 2)
    [int_part, dec_part] = String.split(formatted, ".")

    int_with_separators =
      int_part
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.join(".")
      |> String.reverse()

    "R$\u00A0#{int_with_separators},#{dec_part}"
  end
end
