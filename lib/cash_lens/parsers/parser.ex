defmodule CashLens.Parsers.Parser do
  @moduledoc """
  Defines the behavior for financial statement parsers.
  """

  @type transaction_map :: %{
          date: Date.t(),
          time: Time.t() | nil,
          description: String.t(),
          amount: Decimal.t()
        }

  @callback parse(content :: String.t(), format :: atom()) :: [transaction_map()]
end
