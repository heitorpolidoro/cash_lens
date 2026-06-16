defmodule CashLens.Repo.Migrations.AddCreateMirrorToTransferRules do
  use Ecto.Migration

  def change do
    alter table(:transfer_rules) do
      add :create_mirror, :boolean, default: true, null: false
    end
  end
end
