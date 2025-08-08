defmodule CashLens.Parsers do
  @moduledoc false

  @parsers_list [CashLens.Parsers.BBCSVParser]

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

end
