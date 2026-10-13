defmodule CashLens.Repo.Migrations.AddConfirmationTokensAndLoginAttempts do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :confirmed_at, :utc_datetime
    end

    # Users that exist before email confirmation shipped are treated as confirmed.
    execute "UPDATE users SET confirmed_at = inserted_at WHERE confirmed_at IS NULL", ""

    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :context, :string, null: false
      add :sent_to, :string, null: false
      add :token, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])

    create table(:login_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :email, :string, null: false
      add :success, :boolean, null: false
      add :ip, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:login_attempts, [:user_id])
    create index(:login_attempts, [:inserted_at])
  end
end
