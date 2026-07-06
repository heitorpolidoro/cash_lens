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

  @valid_parsers ~w(bb_csv bradesco_csv mercado_pago_csv standard_ofx ourocard_ofx sem_parar_pdf bradesco_cartao_pdf)

  @doc "Returns the list of valid parser identifiers."
  def valid_parsers, do: @valid_parsers

  @doc "Parses `.account` file content into a map with bank, account, and optional parser/credit_card."
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
      parser = Map.get(fields, "parser")
      credit_card = Map.get(fields, "credit_card", "false") == "true"
      {:ok, %{bank: bank, account: account, parser: parser, credit_card: credit_card}}
    end
  end

  @doc "Validates the parser field if present. Returns :ok or {:error, reason}."
  def validate_parser(%{parser: nil}), do: :ok
  def validate_parser(%{parser: p}) when p in @valid_parsers, do: :ok

  def validate_parser(%{bank: bank, account: account, parser: p}),
    do:
      {:error,
       "conta '#{bank} / #{account}': parser '#{p}' inválido (válidos: #{Enum.join(@valid_parsers, ", ")})"}

  defp fetch(fields, key) do
    case Map.get(fields, key) do
      nil -> {:error, "#{@filename} sem o campo '#{key}'"}
      "" -> {:error, "#{@filename} com '#{key}' vazio"}
      value -> {:ok, value}
    end
  end
end
