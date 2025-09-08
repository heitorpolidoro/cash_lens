defmodule CashLens.ML.TransactionClassifier do
  @moduledoc """
  Thin client to the Python ML API for transaction classification.

  Exposes only two functions:
  - train_model/1 (optionally pass k: integer to limit training rows)
  - predict/1 (expects a map/struct with :datetime, :amount, :reason)
  """

  require Logger

  @python_base_url Application.compile_env(:cash_lens, :python_ml_base_url, "http://localhost:8000")

  @doc """
  Trains (or retrains) the classification model via the Python API.

  Options:
  - :k -> integer, optional (number of recent rows to train on)

  Returns {:ok, map} on success, {:error, reason} on failure.
  """
  def train_model(opts \\ %{}) when is_map(opts) do
    body =
      case Map.get(opts, :k) do
        nil -> %{}
        k when is_integer(k) and k > 0 -> %{k: k}
        other ->
          Logger.warning("Ignoring invalid :k for train_model: #{inspect(other)}")
          %{}
      end

    with {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 <-
           request(:post, "/train", body),
         {:ok, decoded} <- Jason.decode(resp_body) do
      {:ok, decoded}
    else
      {:ok, %Finch.Response{status: 400}} ->
        {:ok, "No enough transactions to train"}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "Training failed with status #{status}: #{resp_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Predicts category_id for a transaction via the Python API.

  Accepts a map or struct with :datetime (DateTime), :amount (Decimal|number), :reason (string).
  Returns {:ok, %{category_id: integer | nil}} or {:error, reason}.
  - category_id: nil when the /predict endpoint responds with 404 (no prediction available).
  """
  def predict(%{datetime: dt, amount: amount, reason: reason}) do
    with {:ok, iso_dt} <- to_iso8601(dt),
         {:ok, amount_f} <- to_float(amount),
         {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 <-
           request(:post, "/predict", %{datetime: iso_dt, amount: amount_f, reason: reason}),
         {:ok, %{"category_id" => category_id}} <- Jason.decode(resp_body) do
      {:ok, %{category_id: category_id}}
    else
      {:ok, %Finch.Response{status: 404}} ->
        # If the Python service cannot predict (e.g., model/category not found),
        # return a successful response with nil category_id as per requirement.
        {:ok, %{category_id: nil}}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "Prediction failed with status #{status}: #{resp_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def predict(_), do: {:error, "Transaction must have datetime, amount, and reason fields"}

  # Internal HTTP helper using Finch
  defp request(method, path, body_map) do
    url = @python_base_url <> path
    headers = [{"content-type", "application/json"}]
    body = Jason.encode!(body_map)
    req = Finch.build(method, url, headers, body)
    Finch.request(req, CashLens.Finch)
  end

  # Utilities
  defp to_iso8601(%DateTime{} = dt), do: {:ok, DateTime.to_iso8601(dt)}
  defp to_iso8601(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> {:ok, DateTime.to_iso8601(dt)}
      {:error, _} = err -> err
    end
  end

  defp to_iso8601(other), do: {:error, "Invalid datetime: #{inspect(other)}"}

  defp to_float(%Decimal{} = d), do: {:ok, Decimal.to_float(d)}
  defp to_float(n) when is_integer(n) or is_float(n), do: {:ok, n * 1.0}
  defp to_float(other), do: {:error, "Invalid amount: #{inspect(other)}"}
end
