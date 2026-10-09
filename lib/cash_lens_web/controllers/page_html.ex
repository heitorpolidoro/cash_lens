defmodule CashLensWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use CashLensWeb, :html

  import CashLensWeb.BankruptcyCard, only: [bankruptcy_card: 1]

  embed_templates "page_html/*"

  @due_soon_days 7

  @doc """
  How a statement's due date reads against today: overdue, due soon, or ahead.

  Overdue comes first because it is the only one that costs money -- interest
  starts the day after, and a bill that slipped is the thing the dashboard most
  needs to say out loud.
  """
  def due_urgency(nil, _today), do: :undated

  def due_urgency(%Date{} = due, %Date{} = today) do
    case Date.diff(due, today) do
      days when days < 0 -> :overdue
      days when days <= @due_soon_days -> :soon
      _ -> :ahead
    end
  end

  @doc """
  Reading of a due date in words, relative to today.
  """
  def due_label(nil, _today), do: "sem vencimento"

  def due_label(%Date{} = due, %Date{} = today) do
    case Date.diff(due, today) do
      0 -> "vence hoje"
      1 -> "vence amanhã"
      days when days > 0 -> "vence em #{days} dias"
      -1 -> "venceu ontem"
      days -> "venceu há #{abs(days)} dias"
    end
  end

  @doc """
  Where a bill row points: a real statement opens on its own screen, and
  anything the projection dated opens on the forecast, which is where its
  registration lives.
  """
  def bill_link(%{statement_id: id}) when not is_nil(id), do: ~p"/statements?id=#{id}"
  def bill_link(_bill), do: ~p"/forecast"

  @doc """
  What a summary bucket says beside its amount.

  An empty bucket says so rather than showing "0 contas" against R$ 0,00, and a
  bucket that holds something says how far out it reaches -- without the date,
  "mais de 7 dias" could be next week or next month.
  """
  def bucket_note(%{count: 0}), do: "nada"
  def bucket_note(%{count: 1, last_date: date}), do: "1 conta · até #{format_date(date)}"
  def bucket_note(%{count: n, last_date: date}), do: "#{n} contas · até #{format_date(date)}"

  @doc """
  Colour for a bill row, by urgency.
  """
  def due_classes(:overdue), do: "text-rose-600"
  def due_classes(:soon), do: "text-amber-600"
  def due_classes(:ahead), do: "text-slate-500"
  def due_classes(:undated), do: "text-slate-400 italic"
end
