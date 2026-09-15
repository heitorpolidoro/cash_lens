defmodule CashLens.Transactions.AmountInput do
  @moduledoc """
  Parsing and formatting for the signed amount field of the manual transaction
  form.

  The form has no "income vs expense" toggle: the sign the user types *is* the
  direction of the money movement, and it is what gets written to
  `Transaction.amount`. A leading `-` means an expense/debit, no sign or a
  leading `+` means income/credit.

  Input is accepted in the formats a Brazilian user actually types —
  `-1.234,56`, `1234,56`, `+50`, `R$ 2.500,00` — as well as the plain
  `1234.56` an English keyboard produces. When a comma is present it is the
  decimal separator, so every dot before it must group exactly three digits:
  mixed-separator typos such as `1,234.56` or `1.23,45` are rejected rather
  than silently coerced, so a typo can never persist a wrong amount.
  """

  # "1.234", "1.234.567" — dots that group exactly three digits are thousand
  # separators, not a decimal point.
  @grouped_thousands ~r/^\d{1,3}(\.\d{3})+$/
  @decimal_number ~r/^\d+(\.\d+)?$/
  # Integer part of a comma-decimal number: either ungrouped digits ("1234") or
  # dots that each group exactly three digits ("1.234", "1.234.567").
  @integer_part ~r/^(\d+|\d{1,3}(\.\d{3})+)$/
  @fractional_part ~r/^\d+$/

  @doc """
  Parses user input into a `Decimal`, preserving the typed sign.

  Returns `{:ok, decimal}`, `:empty` when nothing was typed, or `:error` when
  the input is not a number this field accepts.
  """
  @spec parse(term()) :: {:ok, Decimal.t()} | :empty | :error
  def parse(%Decimal{} = decimal), do: {:ok, decimal}
  def parse(nil), do: :empty

  def parse(value) when is_integer(value) or is_float(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> :error
    end
  end

  def parse(value) when is_binary(value) do
    case sanitize(value) do
      "" -> :empty
      sanitized -> parse_sanitized(sanitized)
    end
  end

  def parse(_value), do: :error

  @doc """
  Classifies raw input as `:expense`, `:income` or `:neutral` for the live
  colour/label feedback, without requiring the value to be complete or valid
  yet — the user gets the hint while still typing.
  """
  @spec kind(term()) :: :expense | :income | :neutral
  def kind(%Decimal{} = decimal) do
    if Decimal.negative?(decimal), do: :expense, else: :income
  end

  def kind(nil), do: :neutral

  def kind(value) when is_binary(value) do
    case sanitize(value) do
      "" -> :neutral
      "-" <> _rest -> :expense
      _positive -> :income
    end
  end

  def kind(value) do
    case parse(value) do
      {:ok, decimal} -> kind(decimal)
      _other -> :neutral
    end
  end

  @doc """
  Renders a stored amount back into the Brazilian format the field accepts, so
  opening and re-saving an existing transaction never flips its sign or loses
  its cents.
  """
  @spec to_input_value(term()) :: String.t()
  def to_input_value(nil), do: ""
  def to_input_value(""), do: ""

  def to_input_value(%Decimal{} = decimal) do
    sign = if Decimal.negative?(decimal), do: "-", else: ""

    {integer_part, fractional_part} =
      decimal
      |> Decimal.abs()
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> String.split(".")
      |> case do
        [integer] -> {integer, "00"}
        [integer, fractional] -> {integer, String.pad_trailing(fractional, 2, "0")}
      end

    "#{sign}#{group_thousands(integer_part)},#{fractional_part}"
  end

  def to_input_value(value) do
    case parse(value) do
      {:ok, decimal} -> to_input_value(decimal)
      _other -> to_string(value)
    end
  end

  defp sanitize(value) do
    value
    |> String.replace(~r/(R\$|\s)/iu, "")
    |> String.trim()
  end

  defp parse_sanitized(sanitized) do
    {sign, digits} = split_sign(sanitized)

    case normalize_separators(digits) do
      :error -> :error
      normalized -> to_decimal(sign <> normalized)
    end
  end

  defp split_sign("-" <> rest), do: {"-", rest}
  defp split_sign("+" <> rest), do: {"", rest}
  defp split_sign(value), do: {"", value}

  defp normalize_separators(""), do: :error

  defp normalize_separators(digits) do
    cond do
      String.contains?(digits, ",") ->
        normalize_comma_decimal(digits)

      Regex.match?(@grouped_thousands, digits) ->
        String.replace(digits, ".", "")

      true ->
        validate_number(digits)
    end
  end

  # The comma is the decimal separator, so every dot before it must be a
  # thousands separator grouping exactly three digits and nothing may follow the
  # cents. "1,234.56" and "1.23,45" are typos, not numbers, and are rejected
  # rather than coerced into an amount 1000x off what the user meant.
  defp normalize_comma_decimal(digits) do
    case String.split(digits, ",") do
      [integer_part, fractional_part] ->
        if Regex.match?(@integer_part, integer_part) and
             Regex.match?(@fractional_part, fractional_part) do
          String.replace(integer_part, ".", "") <> "." <> fractional_part
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp validate_number(candidate) do
    if Regex.match?(@decimal_number, candidate), do: candidate, else: :error
  end

  defp to_decimal(candidate) do
    case Decimal.parse(candidate) do
      {decimal, ""} -> {:ok, decimal}
      _other -> :error
    end
  end

  defp group_thousands(integer_part) do
    integer_part
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(".")
    |> String.reverse()
  end
end
