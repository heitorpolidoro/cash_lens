defmodule CashLens.Parsers do
  @moduledoc false
  import Ecto.Query

  @parsers_list [CashLens.Parsers.BBCSVParser]

  # TODO MOVE to bb_csv_parser
  @text_reason_to_remove [
    "Pagamento .* - ",
    "Pix .* - ",
    "Pagto cartão de crédito - ",
    "Compra com Cartão - "
  ]

  alias CashLens.Reasons
  alias CashLens.Transactions.Transaction
  alias CashLens.Repo

  @doc """
  Returns a list of available parsers with their names and modules.
  """
  def list_parsers do
    @parsers_list
    |> Enum.map(fn parser ->
      %{
        name: parser.name,
        module: parser
      }
    end)
  end

  def parse_file(statement, parser_module, selected_account) do
    # Read file with latin1 encoding
    parsed_transactions =
      statement.path
      |> File.stream!()
      |> Stream.map(&:unicode.characters_to_binary(&1, :latin1))
      |> parser_module.parse
      |> Enum.filter(fn transaction -> !Reasons.should_ignore_reason(transaction.reason) end)
      |> Enum.map(fn transaction ->
        transaction
        |> Map.put(:account, selected_account)
        |> Map.put(:reason, clear_reason(transaction.reason))
        |> Map.put(:refundable, false)
      end)

    # Check for duplicates in the database and within the parsed transactions
    parsed_transactions
    |> Enum.with_index()
    |> Enum.map(fn {transaction, index} ->
      # Check if transaction exists in database
      exists =
        Repo.exists?(
          from(t in Transaction,
            where:
              t.reason == ^transaction.reason and
                t.datetime == ^transaction.datetime and
                t.amount == ^transaction.amount
          )
        ) ||
          Enum.with_index(parsed_transactions)
          |> Enum.any?(fn {t, i} ->
            i != index &&
              t.reason == transaction.reason &&
              t.datetime == transaction.datetime &&
              t.amount == transaction.amount
          end)

      # Mark as existing if it exists in DB or is duplicated in the list
      Map.put(transaction, :exists, exists)
    end)
  end

  defp clear_reason(reason) do
    @text_reason_to_remove
    |> Enum.reduce(reason, fn reason_to_remove, acc ->
      String.replace(acc, Regex.compile!(reason_to_remove), "")
    end)
  end
end
