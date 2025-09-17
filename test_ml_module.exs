# TODO Review
# Test script for the ML module functionality
# Run with: mix run test_ml_module.exs

alias CashLens.Transactions
alias CashLens.ML.TransactionClassifier

IO.puts("=== Testing ML Module Functionality ===\n")

# Test model training
IO.puts("Testing model training...")

case Transactions.train_classification_model() do
  {:ok, message} ->
    IO.puts("✅ Training successful: #{message}")

  {:error, reason} ->
    IO.puts("❌ Training failed: #{reason}")
    IO.puts("This is expected if there are no categorized transactions in the database.")
    IO.puts("Let's create some sample transactions for training...")

    # Create sample transactions for training if none exist
    {:ok, category1} = CashLens.Categories.create_category(%{name: "Groceries"})
    {:ok, category2} = CashLens.Categories.create_category(%{name: "Entertainment"})

    {:ok, account} =
      CashLens.Accounts.create_account(%{name: "Test Account", balance: Decimal.new("1000.00")})

    # Create sample transactions
    Transactions.create_transaction(%{
      datetime: DateTime.utc_now(),
      value: Decimal.new("-75.50"),
      reason: "Supermarket shopping",
      account_id: account.id,
      category_id: category1.id
    })

    Transactions.create_transaction(%{
      datetime: DateTime.utc_now(),
      value: Decimal.new("-120.00"),
      reason: "Movie tickets and dinner",
      account_id: account.id,
      category_id: category2.id
    })

    Transactions.create_transaction(%{
      datetime: DateTime.utc_now(),
      value: Decimal.new("-82.30"),
      reason: "Grocery store",
      account_id: account.id,
      category_id: category1.id
    })

    # Try training again
    IO.puts("\nRetrying training with sample data...")

    case Transactions.train_classification_model() do
      {:ok, message} ->
        IO.puts("✅ Training successful: #{message}")

      {:error, reason} ->
        IO.puts("❌ Training still failed: #{reason}")
    end
end

# Test model loading
IO.puts("\nTesting model loading...")

case TransactionClassifier.load_model() do
  {:ok, model} ->
    IO.puts("✅ Model loaded successfully")
    IO.puts("   Model was trained at: #{model.trained_at}")
    IO.puts("   Number of categories in model: #{map_size(model.category_stats)}")

  {:error, reason} ->
    IO.puts("❌ Model loading failed: #{reason}")
end

# Test prediction
IO.puts("\nTesting prediction...")

test_transaction = %{
  datetime: DateTime.utc_now(),
  value: Decimal.new("-80.00"),
  reason: "Grocery store purchase"
}

case Transactions.predict_transaction_attributes(test_transaction) do
  {:ok, prediction} ->
    IO.puts("✅ Prediction successful")
    IO.puts("   Predicted category_id: #{prediction.category_id}")

    # Get the category name
    category = CashLens.Repo.get(CashLens.Categories.Category, prediction.category_id)

    if category do
      IO.puts("   Category name: #{category.name}")
    end

  {:error, reason} ->
    IO.puts("❌ Prediction failed: #{reason}")
end

# Test create_transaction_with_prediction
IO.puts("\nTesting transaction creation with prediction...")
{:ok, account} = CashLens.Accounts.list_accounts() |> List.first() |> then(&{:ok, &1})

test_transaction = %{
  datetime: DateTime.utc_now(),
  value: Decimal.new("-95.00"),
  reason: "Supermarket weekly shopping",
  account_id: account.id
}

case Transactions.create_transaction_with_prediction(test_transaction) do
  {:ok, transaction} ->
    IO.puts("✅ Transaction created successfully with prediction")
    IO.puts("   Transaction ID: #{transaction.id}")
    IO.puts("   Category ID: #{transaction.category_id}")
    IO.puts("   Category name: #{transaction.category.name}")

  {:error, changeset} ->
    IO.puts("❌ Transaction creation failed:")
    IO.inspect(changeset.errors)
end

IO.puts("\n=== ML Module Testing Complete ===")
