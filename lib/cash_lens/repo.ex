defmodule CashLens.Repo do
  use Ecto.Repo,
    otp_app: :cash_lens,
    adapter: Ecto.Adapters.Postgres

  # Domain rows are user-owned. Callers that do not name an owner get the
  # operator (see `CashLens.Ownership`).
  defoverridable insert: 2, insert!: 2

  def insert(struct_or_changeset, opts) do
    super(CashLens.Ownership.assign(struct_or_changeset), opts)
  end

  def insert!(struct_or_changeset, opts) do
    super(CashLens.Ownership.assign(struct_or_changeset), opts)
  end
end
