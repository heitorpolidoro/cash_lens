defmodule CashLens.Pluggy.LivePreview.Entry do
  @moduledoc """
  One unsaved, live-fetched Pluggy transaction. Never an `Ecto.Schema`, never
  inserted — `CashLens.Pluggy.LivePreview.fetch_all/1` is the only producer.

  `id` is a synthetic, stable-per-real-world-transaction string (derived from
  Pluggy's own transaction id), not a database id — it exists so
  `Phoenix.LiveView.stream_insert/3` can update an entry cleanly across
  refreshes instead of treating every refresh as brand new rows.
  """

  @enforce_keys [:id, :account_id, :date, :description, :amount]
  defstruct [:id, :account_id, :date, :description, :amount, :pluggy_category]

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: Ecto.UUID.t(),
          date: Date.t(),
          description: String.t(),
          amount: Decimal.t(),
          pluggy_category: String.t() | nil
        }
end
