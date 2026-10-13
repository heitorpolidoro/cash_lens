defmodule CashLens.PrivacyTest do
  use CashLens.DataCase, async: true

  import CashLens.UsersFixtures
  alias CashLens.Audit
  alias CashLens.Audit.LoginAttempt
  alias CashLens.Privacy
  alias CashLens.Users
  alias CashLens.Users.User
  alias CashLens.Users.UserToken

  setup do
    user = user_fixture()
    other = user_fixture()
    Audit.record_login_attempt(user, user.email, true, "1.1.1.1")
    Audit.record_login_attempt(other, other.email, true, "2.2.2.2")
    Users.deliver_reset_password_instructions(user, &("http://x/" <> &1))
    Users.deliver_reset_password_instructions(other, &("http://x/" <> &1))
    %{user: user, other: other}
  end

  test "export holds only the user's rows and no secrets", %{user: user, other: other} do
    data = Privacy.export(user)
    json = Jason.encode!(data)

    assert [%{"email" => email}] = data["users"]
    assert email == user.email
    assert length(data["user_tokens"]) == 1
    assert [%{"ip" => "1.1.1.1"}] = data["login_attempts"]
    refute json =~ other.email
    refute json =~ "hashed_password"
    refute json =~ user.hashed_password
    refute json =~ user.session_nonce
    refute json =~ "\"token\""
  end

  test "delete_account/2 with the right password removes every owned row", %{
    user: user,
    other: other
  } do
    assert {:ok, _} = Privacy.delete_account(user, valid_user_password())
    refute Repo.get(User, user.id)
    assert Repo.all(from t in UserToken, where: t.user_id == ^user.id) == []
    assert Repo.all(from a in LoginAttempt, where: a.email == ^user.email) == []
    assert Repo.get(User, other.id)
    assert Repo.aggregate(UserToken, :count) == 1
    assert Repo.aggregate(LoginAttempt, :count) == 1
  end

  test "delete_account/2 with a wrong password changes nothing", %{user: user} do
    assert Privacy.delete_account(user, "wrong") == {:error, :invalid_password}
    assert Repo.get(User, user.id)
    assert Repo.aggregate(UserToken, :count) == 2
  end

  test "registry lists the owned schemas" do
    assert User in Privacy.owned_schemas()
  end
end
