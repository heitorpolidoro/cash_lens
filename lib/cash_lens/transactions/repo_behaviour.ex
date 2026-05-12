defmodule CashLens.Transactions.RepoBehaviour do
  @moduledoc false
  @callback insert(Ecto.Changeset.t(), Keyword.t()) ::
              {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
end
