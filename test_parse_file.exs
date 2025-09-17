# TODO Review
# Test script to verify the transaction prediction functionality
# Run with: mix run test_parse_file.exs

alias CashLens.ML.TransactionClassifier
alias CashLens.Transactions.Transaction

# Create a sample transaction
transaction = %{
  datetime: DateTime.utc_now(),
  value: Decimal.new("100.00"),
  reason: "Test transaction"
}

# Test the prediction function
IO.puts("Testing transaction prediction...")

case TransactionClassifier.predict(transaction) do
  {:ok, prediction} ->
    IO.puts("Prediction successful!")
    IO.puts("Predicted category_id: #{prediction.category_id}")

  {:error, reason} ->
    IO.puts("Prediction failed: #{reason}")
    # This is expected if no model has been trained yet
    IO.puts("You may need to train a model first using:")
    IO.puts("CashLens.Transactions.train_classification_model()")
end

IO.puts("\nTest completed.")
