defmodule CashLensWeb.TransactionsTableComponent do
  use CashLensWeb, :live_component

  require Logger

  alias CashLens.Parsers

  def update(assigns, socket) do
    {:ok, assign(socket, assigns |> Map.put_new(:reason_to_confirm, nil))}
  end

  def render(assigns) do
    CashLensWeb.TransactionsTableComponentHTML.transactions_table(assigns)
  end

  def handle_event("ignore-reason", %{"reason" => reason}, socket) do
    # Show confirmation modal instead of immediately ignoring
    {:noreply, assign(socket, reason_to_confirm: reason)}
  end

  def handle_event("confirm-ignore-reason", _, socket) do
    reason = socket.assigns.reason_to_confirm
    # Clear the reason being confirmed
    socket = assign(socket, reason_to_confirm: nil)

    # Proceed with ignoring the reason
    {:noreply, ignore_reason(reason, socket)}
  end

  def handle_event("cancel-ignore-reason", _, socket) do
    # Clear the reason being confirmed
    {:noreply, assign(socket, reason_to_confirm: nil)}
  end

  defp ignore_reason(reason, socket) do
    parser = socket.assigns.selected_parser

    {level, message} =
      case CashLens.ReasonsToIgnore.create_reason_to_ignore(%{
        reason: reason,
        parser: parser.slug
      }) do
        {:ok, reason} ->
          {:info, "Ignoring reason \"#{reason.reason}\" for #{Parsers.format_parser(parser)}"}

        other ->
          other
      end

    Logger.log(level, message)

    socket
    |> assign(transactions: socket.assigns.transactions
       |> Enum.reject(&(&1.reason == reason)))
    |> put_flash(level, message)
  end
end
