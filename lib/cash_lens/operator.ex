defmodule CashLens.Operator do
  @moduledoc """
  Picks the user that mix tasks and seeds act for.

  Tooling has no logged-in session, so it names its user explicitly: the
  `--user <email>` option, or `CASH_LENS_OPERATOR_EMAIL` for seeds. This is the
  only tooling-side way to choose a user. It lives under `lib/` so it is
  compiled in every environment and reachable from `mix run`.
  """

  import Ecto.Query, only: [from: 2]

  alias CashLens.Repo
  alias CashLens.Users.User

  @usage "pass --user <email> to pick the user the data belongs to"

  @doc """
  Resolves the user to act for and pins it for the calling process (row-level
  security needs a pinned user for every read and write that follows).

    * with an email, returns the user having it, or raises `Mix.Error`;
    * with `nil`, returns the only user, or raises `Mix.Error` when there are
      none or several.

  Never creates a user. Call it before any write.
  """
  def user!(email) when is_binary(email) and email != "" do
    case Repo.get_by(User, email: email) do
      nil -> Mix.raise("no user has the email #{email}")
      user -> pin(user)
    end
  end

  def user!(nil) do
    case Repo.all(from(u in User, limit: 2)) do
      [user] -> pin(user)
      [] -> Mix.raise("no user exists: register one first")
      _several -> Mix.raise("several users exist: #{@usage}")
    end
  end

  def user!(_email), do: user!(nil)

  @doc "Reads the `--user` option out of `args`; returns `{email_or_nil, remaining_args}`."
  def parse_args(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [user: :string])
    {Keyword.get(opts, :user), rest}
  end

  defp pin(user) do
    Repo.put_current_user_id(user.id)
    user
  end
end
