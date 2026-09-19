defmodule CashLens.Imports.ImportRun do
  @moduledoc """
  One executed (never dry-run) file import. The history records *executions*,
  not deltas: re-importing an unchanged file still writes a row, typically with
  `imported_count: 0`.

  `file_path` is denormalized on purpose so the history survives the loss of the
  `imported_files` row it points at.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(success warning error)

  @doc "The valid `status` values."
  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "import_runs" do
    field :ran_at, :utc_datetime
    field :file_path, :string
    field :status, :string
    field :imported_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :error_message, :string

    belongs_to :account, CashLens.Accounts.Account
    belongs_to :imported_file, CashLens.Imports.ImportedFile

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(import_run, attrs) do
    import_run
    |> cast(attrs, [
      :ran_at,
      :account_id,
      :imported_file_id,
      :file_path,
      :status,
      :imported_count,
      :skipped_count,
      :failed_count,
      :error_message
    ])
    |> validate_required([:ran_at, :file_path, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:imported_file_id)
  end
end
