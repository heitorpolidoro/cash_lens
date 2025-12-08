defmodule CashLens.Parsers do
  @parsers_list [CashLens.Parsers.BB_CSV]

  def list_parsers do
    @parsers_list
    |> Enum.map(fn parser ->
      %{
        name: parser.name,
        module: parser,
        slug: get_parser_slug(parser)
      }
    end)
  end

  def parse_statement(statement, parser, account) when is_binary(parser) do
    parse_statement(statement, String.to_atom(parser), account)
  end

  def parse_statement(statement, parser, account) when is_atom(parser) do
    case Enum.find(@parsers_list, fn p ->
           get_parser_slug(p) == parser
         end) do
      parser ->
        # Pass the selected account to the parser so it can attach account reference
        parser.parse_statement(statement, account)

      nil ->
        {:error, :parser_not_found}
    end
  end

  defp get_parser_slug(module) do
    module
    |> Atom.to_string()
    |> String.split(".")
    |> Enum.at(-1)
    |> String.downcase()
    |> String.to_atom()
  end
end
