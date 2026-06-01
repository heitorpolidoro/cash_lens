defmodule CashLens.Transactions.InstallmentDetector do
  @moduledoc """
  Detects installment ("parcelamento") markers in transaction descriptions.

  Brazilian card statements encode installments as "PARC X/Y" (sometimes attached
  to a prefix, e.g. "TIT-PARC 03/12"), meaning this is payment X out of Y total.

  `detect/1` returns the merchant base (everything before the marker, with the
  trailing location/country stripped) plus the current and total installment counts,
  or `nil` when the description is not an installment of more than one payment.
  """

  # Captures: (1) everything before the marker, (2) current number, (3) total
  @marker ~r/^(.*?)\bPARC\s+(\d{1,2})\/(\d{1,2})\b/i

  @doc """
  Parses an installment marker from a description.

  Returns `%{base: String.t(), number: pos_integer(), total: pos_integer()}` or `nil`.
  """
  def detect(nil), do: nil

  def detect(description) when is_binary(description) do
    case Regex.run(@marker, description, capture: :all_but_first) do
      [prefix, number_str, total_str] ->
        number = String.to_integer(number_str)
        total = String.to_integer(total_str)
        base = clean_base(prefix)

        if total > 1 and base != "" do
          %{base: base, number: number, total: total}
        else
          nil
        end

      _ ->
        nil
    end
  end

  def detect(_), do: nil

  # The text before the marker is the merchant; trim trailing separators and
  # collapse internal whitespace so parcels of the same purchase share one base.
  defp clean_base(prefix) do
    prefix
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.replace(~r/[\s\-]+$/, "")
    |> String.trim()
  end
end
