defmodule CashLens.Repo.Migrations.AddReimbursementDetailsToTransactions do
  use Ecto.Migration

  # The reimbursement hub lets the user record, per reimbursable expense, which
  # health-plan/company ("convenio") the request was filed with and the protocol
  # number returned by it. Both are free-form identifiers coming from the third
  # party, so they are plain strings with no constraint.
  def change do
    alter table(:transactions) do
      add :reimbursement_carrier, :string
      add :reimbursement_protocol, :string
    end
  end
end
