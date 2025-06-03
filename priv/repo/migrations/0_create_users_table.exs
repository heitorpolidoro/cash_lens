defmodule CashLens.Repo.Migrations.CreateUsersTable do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:name, :string, null: false)
      add(:email, :string, null: false)
      add(:sub, :string, null: false)

      timestamps()
    end

    create(unique_index(:users, [:email]))
    create(unique_index(:users, [:sub]))
  end
end
