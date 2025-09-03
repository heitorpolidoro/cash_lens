defmodule CashLens.ML.TransactionClassifier do
  @moduledoc """
  Machine learning module for transaction classification.

  This module provides functionality to:
  - Train a supervised classification model using transaction data
  - Save the trained model to disk
  - Load a previously trained model
  - Predict category for new transactions

  The model uses transaction datetime, value, and reason as input features
  to predict category_id.
  """

  alias CashLens.Transactions.Transaction
  alias CashLens.Repo
  import Ecto.Query

  # Define the path where the model will be saved
  @model_path "priv/ml_models/transaction_classifier.model"

  @doc """
  Trains a new classification model using transaction data from the database.

  Returns `:ok` if training was successful, or `{:error, reason}` if it failed.
  """
  def train_model do
    # Fetch all transactions with their categories
    transactions =
      Transaction
      |> where([t], not is_nil(t.category_id))
      |> Repo.all()
      |> Repo.preload(:category)

    if Enum.empty?(transactions) do
      {:error, "No transactions with categories found for training"}
    else
      # Extract features and labels
      {features, labels} = prepare_training_data(transactions)

      # Train the model (simplified implementation)
      model = train_classifier(features, labels)

      # Save the trained model
      save_model(model)
    end
  end

  @doc """
  Loads a previously trained model from disk.

  Returns `{:ok, model}` if successful, or `{:error, reason}` if it failed.
  """
  def load_model do
    if File.exists?(@model_path) do
      try do
        model = @model_path |> File.read!() |> :erlang.binary_to_term()
        {:ok, model}
      rescue
        e -> {:error, "Failed to load model: #{inspect(e)}"}
      end
    else
      {:error, "Model file not found at #{@model_path}"}
    end
  end

  @doc """
  Predicts category_id for a transaction.

  Takes a transaction map or struct with at least :datetime, :amount, and :reason fields.
  Returns `{:ok, %{category_id: id}}` if successful,
  or `{:error, reason}` if prediction failed.
  """
  def predict(%{datetime: datetime, amount: amount, reason: reason} = _transaction) do
    with {:ok, model} <- load_model(),
         features <- extract_features(datetime, amount, reason) do
      # Make prediction using the model (simplified implementation)
      prediction = predict_with_model(model, features)
      {:ok, prediction}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def predict(_transaction) do
    {:error, "Transaction must have datetime, amount, and reason fields"}
  end

  # Private functions

  defp prepare_training_data(transactions) do
    features =
      Enum.map(transactions, fn t ->
        extract_features(t.datetime, t.amount, t.reason)
      end)

    labels =
      Enum.map(transactions, fn t ->
        %{category_id: t.category_id}
      end)

    {features, labels}
  end

  defp extract_features(datetime, amount, reason) do
    # Extract numerical features from datetime
    day_of_week = datetime.day
    month = datetime.month
    day_of_month = datetime.day

    #     Convert amount to float
    amount_float =
      if is_struct(amount, Decimal) do
        Decimal.to_float(amount)
      else
        amount
      end

    # Extract features from reason (simplified)
    # In a real implementation, you would use NLP techniques
    reason_length = if is_nil(reason), do: 0, else: String.length(reason)
    reason_words = if is_nil(reason), do: 0, else: length(String.split(reason))

    # Return feature vector
    %{
      day_of_week: day_of_week,
      month: month,
      day_of_month: day_of_month,
      amount: amount_float,
      reason_length: reason_length,
      reason_words: reason_words
    }
  end

  defp train_classifier(features, labels) do
    # This is a simplified implementation
    # In a real implementation, you would use a proper ML algorithm
    # For now, we'll just create a simple model based on patterns in the data

    # Group transactions by category_id and calculate statistics
    category_stats =
      Enum.reduce(Enum.zip(features, labels), %{}, fn {feature, label}, acc ->
        category_id = label.category_id

        category_data =
          Map.get(acc, category_id, %{
            count: 0,
            total_amount: 0,
            reason_patterns: %{}
          })

        # Update statistics
        updated_data = %{
          count: category_data.count + 1,
          total_amount: category_data.total_amount + feature.amount,
          reason_patterns: update_reason_patterns(category_data.reason_patterns, feature)
        }

        Map.put(acc, category_id, updated_data)
      end)

    # Create a simple model with category statistics
    %{
      category_stats: category_stats,
      trained_at: DateTime.utc_now()
    }
  end

  defp update_reason_patterns(patterns, _feature) do
    # This is a simplified implementation
    # In a real implementation, you would use more sophisticated NLP techniques
    patterns
  end

  defp predict_with_model(model, features) do
    # This is a simplified implementation
    # In a real implementation, you would use the trained model to make predictions

    # Find the most likely category based on amount and other features
    {category_id, _category_data} =
      Enum.max_by(model.category_stats, fn {_id, data} ->
        # Simple scoring based on amount similarity
        amount_similarity = 1 / (1 + abs(features.amount - data.total_amount / data.count))

        # You would use more sophisticated scoring in a real implementation
        amount_similarity
      end)

    %{category_id: category_id}
  end

  defp save_model(model) do
    # Ensure directory exists
    File.mkdir_p!(Path.dirname(@model_path))

    # Serialize and save the model
    serialized_model = :erlang.term_to_binary(model)

    case File.write(@model_path, serialized_model) do
      :ok -> {:ok, "Model saved successfully"}
      {:error, reason} -> {:error, "Failed to save model: #{inspect(reason)}"}
    end
  end
end
