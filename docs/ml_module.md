# Transaction Classification ML Module

This document describes the machine learning module for transaction classification in CashLens.

## Overview

The ML module provides functionality to automatically categorize transactions and predict whether they are refundable based on their attributes. This helps users by:

1. Reducing manual categorization work
2. Ensuring consistent categorization of similar transactions
3. Improving the accuracy of financial reports and analysis

## Architecture

The ML module consists of the following components:

1. **TransactionClassifier** (`CashLens.ML.TransactionClassifier`) - Core module that handles training, saving, loading, and prediction
2. **ModelWorker** (`CashLens.ML.ModelWorker`) - GenServer that loads the model on application startup
3. **Transactions Context Integration** - Functions in the Transactions context that use the ML module

## Features

### Model Training

The model is trained using existing transaction data from the database. It learns to associate transaction attributes (datetime, value, reason) with categories and refundable status.

```elixir
# Train the model
CashLens.Transactions.train_classification_model()
```

The model is automatically saved after training and loaded by the ModelWorker.

### Prediction

The ML module can predict the category and refundable status for new transactions:

```elixir
# Predict category and refundable status for a transaction
transaction = %{
  datetime: DateTime.utc_now(),
  value: Decimal.new("-75.50"),
  reason: "Grocery shopping"
}

CashLens.Transactions.predict_transaction_attributes(transaction)
# Returns: {:ok, %{category_id: 1, refundable: false}}
```

### Automatic Categorization

When creating a new transaction, you can use the `create_transaction_with_prediction` function to automatically categorize it:

```elixir
# Create a transaction with automatic categorization
transaction = %{
  datetime: DateTime.utc_now(),
  value: Decimal.new("-75.50"),
  reason: "Grocery shopping",
  account_id: 1
}

CashLens.Transactions.create_transaction_with_prediction(transaction)
# Returns: {:ok, %Transaction{...}}
```

## Implementation Details

### Feature Extraction

The model extracts the following features from transactions:

- **Datetime**: Day of week, month, day of month
- **Value**: Transaction amount as a float
- **Reason**: Length of reason text, number of words

### Model Persistence

The trained model is saved to disk at `priv/ml_models/transaction_classifier.model` and loaded automatically when the application starts.

### Error Handling

The ML module includes robust error handling:

- If no model exists, predictions will fail gracefully
- If training fails, appropriate error messages are returned
- The ModelWorker will retry loading the model if it fails initially

## Best Practices

1. **Train the model regularly** - As more transactions are added, retrain the model to improve accuracy
2. **Provide meaningful reason text** - The model uses the reason text to make predictions, so more descriptive reasons lead to better predictions
3. **Verify predictions** - While the model aims to be accurate, it's good practice to verify its predictions, especially for important transactions

## Future Improvements

Potential future improvements to the ML module include:

1. More sophisticated NLP techniques for analyzing reason text
2. Time-based features to capture seasonal patterns
3. Confidence scores for predictions
4. User feedback mechanism to improve the model
5. Support for more complex ML algorithms
