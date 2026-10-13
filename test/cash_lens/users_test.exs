defmodule CashLens.UsersTest do
  use CashLens.DataCase, async: true

  alias CashLens.Users
  alias CashLens.Users.User
  import CashLens.UsersFixtures

  test "registration stores a hashed password and enabled == false" do
    {:ok, user} = Users.register_user(valid_user_attributes(%{password: "plain-password-123"}))

    refute user.enabled
    assert user.hashed_password != "plain-password-123"
    assert user.hashed_password =~ "$2b$"
    assert is_nil(user.password)
  end

  test "enabled cannot be set through registration" do
    {:ok, user} = Users.register_user(valid_user_attributes(%{enabled: true}))
    refute user.enabled
  end

  test "duplicate email differing only by case is rejected" do
    user_fixture(%{email: "Person@Example.com"})
    {:error, cs} = Users.register_user(valid_user_attributes(%{email: "person@example.COM"}))
    assert "has already been taken" in errors_on(cs).email
  end

  test "the database enforces case-insensitive uniqueness" do
    user_fixture(%{email: "dup@example.com"})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%User{email: "DUP@example.com", hashed_password: "x", session_nonce: "n"})
    end
  end

  test "invalid email and short password are rejected" do
    {:error, cs} = Users.register_user(%{email: "not an email", password: "short"})
    assert %{email: [_], password: [_]} = errors_on(cs)

    {:error, cs} = Users.register_user(%{})
    assert "can't be blank" in errors_on(cs).email
  end

  describe "password policy" do
    defp password_errors(attrs) do
      {:error, cs} = Users.register_user(valid_user_attributes(attrs))
      errors_on(cs).password
    end

    test "a common password is rejected, whatever its case" do
      assert ["is too common"] = password_errors(%{password: "qwertyuiop12"})
      assert ["is too common"] = password_errors(%{password: "QwertyUiop12"})
    end

    test "a password equal to the email or its local part is rejected" do
      assert ["is too similar to your email"] =
               password_errors(%{
                 email: "marianaoliveira@example.com",
                 password: "marianaoliveira"
               })

      assert ["is too similar to your email"] =
               password_errors(%{
                 email: "marianaoliveira@example.com",
                 password: "MarianaOliveira"
               })

      assert ["is too similar to your email"] =
               password_errors(%{
                 email: "mariana.oliveira@ex.com",
                 password: "mariana.oliveira@ex.com"
               })
    end

    test "an 11-character password is rejected" do
      assert [message] = password_errors(%{password: "x7#kQ9!mZ2p"})
      assert message =~ "at least 12"
    end

    test "a password over 72 bytes is rejected, counting bytes not characters" do
      assert [message] = password_errors(%{password: String.duplicate("é", 37)})
      assert message =~ "at most 72"
    end

    test "a strong password of 12 or more characters is accepted" do
      assert {:ok, _} = Users.register_user(valid_user_attributes(%{password: "x7#kQ9!mZ2pL"}))
    end

    test "log in is not subject to the policy" do
      {:ok, user} =
        %User{}
        |> Ecto.Changeset.change(
          email: "legacy@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password"),
          session_nonce: "n"
        )
        |> Repo.insert()

      assert Users.get_user_by_email_and_password("legacy@example.com", "password").id == user.id
    end
  end

  test "the enabled column is NOT NULL" do
    assert_raise Postgrex.Error, ~r/not_null_violation|null value/, fn ->
      Repo.query!(
        "INSERT INTO users (id, email, hashed_password, enabled, inserted_at, updated_at) VALUES (gen_random_uuid(), 'a@b.c', 'x', NULL, now(), now())"
      )
    end
  end

  test "the enabled column defaults to false at the database level" do
    %{rows: [[enabled]]} =
      Repo.query!(
        "INSERT INTO users (id, email, hashed_password, inserted_at, updated_at) VALUES (gen_random_uuid(), 'd@b.c', 'x', now(), now()) RETURNING enabled"
      )

    assert enabled == false
  end

  test "email lookup is case-insensitive and password check works" do
    user = user_fixture(%{email: "Mixed@Example.com"})

    assert Users.get_user_by_email_and_password("mixed@example.com", valid_user_password()).id ==
             user.id

    refute Users.get_user_by_email_and_password("mixed@example.com", "wrong")
    refute Users.get_user_by_email_and_password("nobody@example.com", "wrong")
    refute Users.get_user_by_email_and_password(nil, nil)
  end

  test "get_user tolerates junk ids" do
    refute Users.get_user("nope")
    refute Users.get_user(nil)
    refute Users.get_user(Ecto.UUID.generate())
  end

  test "rotating the nonce changes it" do
    user = user_fixture()
    {:ok, rotated} = Users.rotate_session_nonce(user)
    assert rotated.session_nonce != user.session_nonce
  end
end
