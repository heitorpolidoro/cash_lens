defmodule CashLens.Transactions.BulkIgnorePattern do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bulk_ignore_patterns" do
    field :pattern, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(bulk_ignore_pattern, attrs) do
    bulk_ignore_pattern
    |> cast(attrs, [:pattern, :description])
    |> validate_required([:pattern])
    |> unique_constraint(:pattern)
    |> validate_regex()
  end

  defp validate_regex(changeset) do
    if pattern = get_change(changeset, :pattern) do
      case Regex.compile(pattern) do
        {:ok, _} -> changeset
        {:error, _} -> add_error(changeset, :pattern, "Regex inválida")
      end
    else
      changeset
    end
  end
end
