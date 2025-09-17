defmodule CashLens.TransferManager do
  @moduledoc """
  A simple GenServer that subscribes to transaction updates.

  This server listens to the "transaction_updates" PubSub topic and
  performs a dummy action when a message is received.
  """
  use GenServer
  require Logger

  alias CashLens.Transfers
  alias CashLens.AutomaticTransfers
  alias CashLens.Transactions

  # Client API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dummy public handler that could be expanded later.
  Currently it just logs and returns :ok.
  """
  def dummy_handle_update(message) do
    Logger.debug("TransferManager.dummy_handle_update/1 called with: #{inspect(message)}")
    :ok
  end

  # Server (callbacks)
  @impl true
  def init(_opts) do
    # Subscribe to transaction updates topic
    Phoenix.PubSub.subscribe(CashLens.PubSub, "transaction_updates")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:transaction_created, %{category: %{name: "Transfer"} = transaction}}, state) do
    if other_transaction = Transfers.find_existing_transfer_transaction(transaction) do
      Transfers.update_transfer_from_transactions(other_transaction, transaction)
    else
      if account = AutomaticTransfers.find_automatic_transfer_account_to!(transaction.account) do
        # Create the transaction in the "other" account with the same amount but in the opposite direction
        {:ok, other_transaction} =
          Transactions.create_transaction(%{
            Map.from_struct(transaction)
            | account_id: account.id,
              amount: Decimal.negate(transaction.amount)
          })

        Transfers.create_transfer_from_transactions(transaction, other_transaction)
      else
        Transfers.create_transfer_from_transactions(transaction, nil)
      end
    end

    #    dummy_handle_update(msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({event, transaction}, state) do
    Logger.debug(
      "TransferManager received the message: #{event} with category #{transaction.category.name}"
    )

    {:noreply, state}
  end
end
#
#defmodule ThrottledHandler do
#  use GenServer
#
#  @cooldown 5_000  # milliseconds
#
#  def start_link(_) do
#    GenServer.start_link(__MODULE__, %{last_time: nil}, name: __MODULE__)
#  end
#
#  def trigger(data) do
#    GenServer.cast(__MODULE__, {:event, data})
#  end
#
#  def handle_cast({:event, data}, %{last_time: nil} = state) do
#    # First time: process immediately
#    process(data)
#    timer = Process.send_after(self(), :reset, @cooldown)
#    {:noreply, %{state | last_time: timer}}
#  end
#
#  def handle_cast({:event, _data}, state) do
#    # Ignore if still in cooldown
#    {:noreply, state}
#  end
#
#  def handle_info(:reset, state) do
#    {:noreply, %{state | last_time: nil}}
#  end
#
#  defp process(data) do
#    IO.puts("Processing: #{inspect(data)}")
#  end
#end
