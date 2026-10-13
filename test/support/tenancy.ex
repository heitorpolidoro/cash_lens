defmodule CashLens.Tenancy do
  @moduledoc """
  Test helpers for multi-tenant scenarios.

  `cross_tenant/1` creates two users; `pop_user/1` and `acting_as/2` are what
  the domain fixtures use to build a row for an explicit `:user`.
  """

  alias CashLens.Repo
  alias CashLens.UsersFixtures

  @doc """
  Creates users A and B. Returns `%{a: a, b: b}`, or, given a function, the
  result of `fun.(a, b)`. The calling process stays pinned as it was found.
  """
  def cross_tenant(fun \\ nil) do
    previous = Repo.current_user_id()
    a = UsersFixtures.user_fixture()
    b = UsersFixtures.user_fixture()
    Repo.put_current_user_id(previous)

    if is_function(fun, 2), do: fun.(a, b), else: %{a: a, b: b}
  end

  @doc """
  Splits `:user` off `attrs` and returns `{user, attrs}`. The user defaults to
  the one pinned for the process, else a fresh one.
  """
  def pop_user(attrs) do
    case attrs |> Map.new() |> Map.pop(:user) do
      {nil, rest} -> {default_user(), rest}
      {user, rest} -> {user, rest}
    end
  end

  @doc "Runs `fun` acting as `user`."
  def acting_as(%{id: user_id}, fun), do: Repo.with_user(user_id, fun)

  defp default_user do
    case Repo.current_user_id() do
      nil -> UsersFixtures.user_fixture()
      id -> %CashLens.Users.User{id: id}
    end
  end
end
