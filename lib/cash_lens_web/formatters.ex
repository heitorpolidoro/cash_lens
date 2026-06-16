defmodule CashLensWeb.Formatters do
  @moduledoc """
  Helpers for formatting data in the UI.
  """

  def account_label(%{bank: bank, name: name}), do: "#{bank} - #{name}"

  @doc """
  Formats a decimal or float as Brazilian currency (BRL).
  Example: 1234.5 -> R$ 1.234,50
  """
  def format_currency(nil), do: "R$ 0,00"

  def format_currency(amount) do
    decimal = Decimal.cast(amount) |> elem(1) |> Decimal.round(2)
    is_negative = Decimal.lt?(decimal, 0)
    abs_decimal = Decimal.abs(decimal)

    {int_part, frac_part} =
      abs_decimal
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

    prefix = if is_negative, do: "R$ -", else: "R$ "
    "#{prefix}#{formatted_int},#{frac_part}"
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

  @doc """
  Formats a Time struct as HH:MM.
  """
  def format_time(nil), do: ""

  def format_time(%Time{} = time) do
    Time.truncate(time, :second) |> Time.to_string() |> String.slice(0..4)
  end

  @abbreviated_weekdays ~w(seg ter qua qui sex sáb dom)
  @full_weekdays [
    "Segunda-feira",
    "Terça-feira",
    "Quarta-feira",
    "Quinta-feira",
    "Sexta-feira",
    "Sábado",
    "Domingo"
  ]
  @abbreviated_months ~w(jan fev mar abr mai jun jul ago set out nov dez)
  @full_months ~w(Janeiro Fevereiro Março Abril Maio Junho
                  Julho Agosto Setembro Outubro Novembro Dezembro)

  @doc """
  Returns the abbreviated weekday name in Portuguese (e.g. "sex").
  """
  def format_weekday(%Date{} = date) do
    Enum.at(@abbreviated_weekdays, Date.day_of_week(date) - 1)
  end

  @doc """
  Returns the full weekday name in Portuguese (e.g. "Sexta-feira").
  """
  def format_weekday_full(%Date{} = date) do
    Enum.at(@full_weekdays, Date.day_of_week(date) - 1)
  end

  @doc """
  Translates reimbursement status to Portuguese.
  """
  def translate_reimbursement_status(nil, _amount), do: ""
  def translate_reimbursement_status("pending", _amount), do: "Pendente"
  def translate_reimbursement_status("requested", _amount), do: "Solicitado"

  def translate_reimbursement_status("paid", amount) do
    if Decimal.lt?(amount, 0), do: "Reembolso Pago", else: "Reembolso"
  end

  def translate_reimbursement_status(other, _amount), do: String.capitalize(other)

  @doc """
  Returns abbreviated month name in Portuguese for a 1-based month integer.
  """
  def month_label(m), do: Enum.at(@abbreviated_months, m - 1)

  @doc """
  Returns the full month name in Portuguese for a 1-based month integer.
  """
  def month_name(m), do: Enum.at(@full_months, m - 1)

  @doc """
  Translates parser types to human readable names.
  """
  def translate_parser_type("bb_csv"), do: "Banco do Brasil (CSV)"
  def translate_parser_type("bradesco_csv"), do: "Bradesco (CSV)"
  def translate_parser_type("bradesco_cartao_pdf"), do: "Bradesco Cartão (PDF)"
  def translate_parser_type("mercado_pago_csv"), do: "Mercado Pago (CSV)"
  def translate_parser_type("ourocard_ofx"), do: "Ourocard (OFX)"
  def translate_parser_type("sem_parar_pdf"), do: "Sem Parar (PDF)"
  def translate_parser_type("standard_ofx"), do: "OFX Padrão"
  def translate_parser_type(_), do: "Não configurado"
end
