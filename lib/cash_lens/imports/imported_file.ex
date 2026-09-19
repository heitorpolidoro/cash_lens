defmodule CashLens.Imports.ImportedFile do
  @moduledoc """
  One statement file the importer has already ingested, identified by its
  `path` key (root-relative when a monitored root is configured, absolute
  otherwise — see `CashLens.Imports.relative_path/2`).

  `content_hash` and `mtime` are the values measured on disk at the moment of
  the last successful import; comparing them against the current disk state is
  what lets `CashLens.Imports.scan/1` tell `:synced` from `:updated`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "imported_files" do
    field :path, :string
    field :content_hash, :string
    field :mtime, :utc_datetime
    field :last_imported_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(imported_file, attrs) do
    imported_file
    |> cast(attrs, [:path, :content_hash, :mtime, :last_imported_at])
    |> validate_required([:path])
    |> unique_constraint(:path)
  end
end
