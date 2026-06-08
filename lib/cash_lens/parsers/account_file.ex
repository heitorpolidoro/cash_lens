defmodule CashLens.Parsers.AccountFile do
  @moduledoc """
  Parses `.account` marker files that declare which account a folder belongs to.

  Format (one `key: value` per line; blank lines and `#` comments ignored):

      bank: Banco do Brasil
      account: Conta Corrente
  """

  @filename ".account"

  @doc "The marker filename (`.account`)."
  def filename, do: @filename

  @doc "Whether a `.account` file exists in `dir`."
  def exists?(dir), do: File.exists?(Path.join(dir, @filename))

  @doc "Reads and parses the `.account` file in `dir`."
  def read(dir) do
    path = Path.join(dir, @filename)

    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, "não foi possível ler #{@filename}: #{reason}"}
    end
  end

  @doc "Parses `.account` file content into `%{bank: ..., account: ...}`."
  def parse(content) do
    fields =
      content
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            Map.put(acc, key |> String.trim() |> String.downcase(), String.trim(value))

          _ ->
            acc
        end
      end)

    with {:ok, bank} <- fetch(fields, "bank"),
         {:ok, account} <- fetch(fields, "account") do
      {:ok, %{bank: bank, account: account}}
    end
  end

  defp fetch(fields, key) do
    case Map.get(fields, key) do
      nil -> {:error, "#{@filename} sem o campo '#{key}'"}
      "" -> {:error, "#{@filename} com '#{key}' vazio"}
      value -> {:ok, value}
    end
  end
end
