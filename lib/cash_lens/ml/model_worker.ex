defmodule CashLens.ML.ModelWorker do
  @moduledoc """
  Worker process that loads the ML model on application startup.

  This module ensures that the transaction classification model is loaded
  when the application starts, making it available for predictions.
  """

  use GenServer
  require Logger
  alias CashLens.ML.TransactionClassifier

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_state) do
    # Load the model asynchronously to avoid blocking application startup
    send(self(), :load_model)
    {:ok, %{model_loaded: false}}
  end

  @impl true
  def handle_info(:load_model, state) do
    case TransactionClassifier.load_model() do
      {:ok, _model} ->
        Logger.info("Transaction classification model loaded successfully")
        {:noreply, %{state | model_loaded: true}}

      {:error, reason} ->
        Logger.warning("Failed to load transaction classification model: #{reason}")
        # Schedule a retry after 5 minutes
        Process.send_after(self(), :load_model, 5 * 60 * 1000)
        {:noreply, state}
    end
  end

  @doc """
  Checks if the model is loaded.

  Returns `true` if the model is loaded, `false` otherwise.
  """
  def model_loaded? do
    GenServer.call(__MODULE__, :model_loaded?)
  end

  @impl true
  def handle_call(:model_loaded?, _from, state) do
    {:reply, state.model_loaded, state}
  end

  @doc """
  Triggers a model reload.

  This can be used to reload the model after training a new one.
  """
  def reload_model do
    GenServer.cast(__MODULE__, :reload_model)
  end

  @impl true
  def handle_cast(:reload_model, state) do
    send(self(), :load_model)
    {:noreply, %{state | model_loaded: false}}
  end
end
