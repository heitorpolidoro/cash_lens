defmodule Mix.Tasks.CashLens.Db.Provision do
  @shortdoc "Creates/updates the unprivileged runtime role (priv/repo/roles.sql)"
  @moduledoc """
  Applies `priv/repo/roles.sql` as the owner role (`CashLens.MigrationRepo`),
  without needing `psql`. Idempotent; the `test` alias runs it after the
  migrations, and it should be run after every deploy that migrates.

  The role password is `CASH_LENS_APP_PASSWORD`, falling back to the password in
  the `CashLens.Repo` config, so in dev and test the role matches what the Repo
  connects with.

      mix cash_lens.db.provision
  """
  use Mix.Task

  alias Ecto.Adapters.SQL

  @roles_sql Path.expand("../../../priv/repo/roles.sql", __DIR__)
  @external_resource @roles_sql

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    password =
      System.get_env("CASH_LENS_APP_PASSWORD") ||
        Application.get_env(:cash_lens, CashLens.Repo)[:password] ||
        Mix.raise("set CASH_LENS_APP_PASSWORD (no password in the Repo config)")

    statements = @roles_sql |> File.read!() |> statements(password)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(CashLens.MigrationRepo, fn repo ->
        # One transaction = one connection, so the session setting made by the
        # first statement is visible to the DO blocks that follow.
        repo.transaction(fn ->
          # log: false, because the first statement carries the password.
          Enum.each(statements, &SQL.query!(repo, &1, [], log: false))
        end)
      end)

    :ok
  end

  @doc false
  # Turns the psql script into single statements: comments dropped, the psql
  # variable `:'app_password'` replaced by a quoted literal, split on `;` at the
  # end of a line outside `$$` bodies.
  def statements(script, password) do
    literal = "'" <> String.replace(password, "'", "''") <> "'"

    script
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "--"))
    |> Enum.join("\n")
    |> String.replace(":'app_password'", literal)
    |> split()
  end

  defp split(sql) do
    {done, current, _in_body?} =
      sql
      |> String.split("\n")
      |> Enum.reduce({[], [], false}, fn line, {done, current, in_body?} ->
        in_body? = if rem(count_markers(line), 2) == 1, do: not in_body?, else: in_body?
        current = [line | current]

        if not in_body? and String.ends_with?(String.trim_trailing(line), ";") do
          {[current |> Enum.reverse() |> Enum.join("\n") |> String.trim() | done], [], in_body?}
        else
          {done, current, in_body?}
        end
      end)

    leftover = current |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    Enum.reverse(if leftover == "", do: done, else: [leftover | done])
  end

  defp count_markers(line), do: length(String.split(line, "$$")) - 1
end
