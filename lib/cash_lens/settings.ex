defmodule CashLens.Settings do
  @moduledoc """
  Tiny key-value persistence for UI preferences that should survive page
  reloads and server restarts (e.g. the last folder used for batch import).
  Backed by a single JSON file — not meant for anything beyond a handful of
  small, infrequently-written preferences.
  """

  @filename "settings.json"

  @doc "Reads a stored value by key, or returns `default` when absent/unreadable."
  def get(key, default \\ nil) when is_binary(key) do
    case File.read(path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{^key => value}} -> value
          _ -> default
        end

      _ ->
        default
    end
  end

  @doc "Persists a single key, merging with whatever is already stored."
  def put(key, value) when is_binary(key) do
    current =
      case File.read(path()) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.write(path(), Jason.encode!(Map.put(current, key, value)))
  end

  defp path, do: Path.join(:code.priv_dir(:cash_lens), @filename)
end
