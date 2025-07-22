defmodule CashLensWeb.TransactionsTableComponent do
  use CashLensWeb, :live_component

  require Logger

  alias CashLens.Parsers
  alias CashLens.Transactions

  def update(assigns, socket) do
    {:ok, assign(socket, assigns |> Map.put_new(:reason_to_ignore, nil))}
  end

  def render(assigns) do
    CashLensWeb.TransactionsTableComponentHTML.transactions_table(assigns)
  end

  def handle_event("ignore-reason", %{"reason" => reason}, socket) do
    # Show confirmation modal instead of immediately ignoring
    {:noreply, assign(socket, reason_to_ignore: reason)}
  end

  def handle_event("confirm-ignore-reason", _, socket) do
    reason = socket.assigns.reason_to_ignore
    # Clear the reason being confirmed
    socket = assign(socket, reason_to_ignore: nil)

    # Proceed with ignoring the reason
    {:noreply, ignore_reason(reason, socket)}
  end

  def handle_event("cancel-ignore-reason", _, socket) do
    # Clear the reason being confirmed
    {:noreply, assign(socket, reason_to_ignore: nil)}
  end

  def handle_event("category-change", %{"category_select" => "new"}= _params, socket) do
    IO.inspect("NEW")

    {:noreply, socket}
  end

  def handle_event("category-change", %{"index" => index, "category_select" => category_select} = _params, socket) do
    IO.puts("\n\n\n---------------------CATEGORY CHANGE")
    transactions = socket.assigns.transactions.result |> IO.inspect



    {:noreply, assign_async(socket, :transactions, fn -> {:ok,
      %{transactions: List.update_at(transactions, String.to_integer(index), fn transaction ->
        %{transaction |category_id: String.to_integer(category_select)}
      end)}}
    end)
    }
  end

  defp ignore_reason(reason, socket) do
    %{selected_parser: parser, transactions: transactions} = socket.assigns

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
    |> assign_async(:transactions, fn ->
      {:ok, %{transactions: transactions.result
        |> Enum.reject(&(&1.reason == reason))}}
      end)
    |> put_flash(level, message)
  end
end
