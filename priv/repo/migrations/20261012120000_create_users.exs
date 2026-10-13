defmodule CashLens.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :enabled, :boolean, null: false, default: false

      # Cookie sessions are stateless, so a logout cannot revoke the cookie by
      # itself. The session carries this nonce and logout rotates it, which
      # makes every earlier cookie stop matching.
      add :session_nonce, :string, null: false, default: fragment("md5(random()::text)")

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
  end
end
