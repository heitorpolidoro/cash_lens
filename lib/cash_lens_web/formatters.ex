defmodule CashLensWeb.Formatters do
  @moduledoc """
  Helpers for formatting data in the UI.
  """

  @doc """
  Formats a decimal or float as Brazilian currency (BRL).
  Example: 1234.5 -> R$ 1.234,50
  """
  def format_currency(nil), do: "R$ 0,00"
  def format_currency(amount) do
    decimal = Decimal.cast(amount) |> elem(1) |> Decimal.round(2)
    
    {int_part, frac_part} = 
      decimal
      |> Decimal.to_string(:normal)
      |> String.split(".")
      |> case do
        [int] -> {int, "00"}
        [int, frac] -> {int, String.pad_trailing(frac, 2, "0")}
      end

    formatted_int = 
      int_part
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.join(".")
      |> String.reverse()

    "R$ #{formatted_int},#{frac_part}"
  end

  @doc """
  Formats a Date struct as DD/MM/YYYY.
  """
  def format_date(nil), do: ""
  def format_date(%Date{} = date) do
    Calendar.strftime(date, "%d/%m/%Y")
  end
  def format_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> format_date(date)
      _ -> date_string
    end
  end
end
