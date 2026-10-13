defmodule CashLens.UsersTokensTest do
  use CashLens.DataCase, async: true

  import CashLens.UsersFixtures
  alias CashLens.Users
  alias CashLens.Users.UserToken

  defp url(token), do: "http://localhost/t/" <> token

  defp age(context, hours) do
    past = DateTime.utc_now() |> DateTime.add(-hours, :hour) |> DateTime.truncate(:second)
    Repo.update_all(from(t in UserToken, where: t.context == ^context), set: [inserted_at: past])
  end

  test "stores only the hash of the token" do
    user = user_fixture(%{confirmed: false})
    {:ok, email} = Users.deliver_confirmation_instructions(user, &url/1)
    raw = extract_token(email)
    stored = Repo.one!(UserToken)
    refute stored.token == raw
    refute stored.token == Base.url_decode64!(raw, padding: false)
    assert byte_size(stored.token) == 32
  end

  test "confirm_user/1 confirms once and rejects reuse" do
    user = user_fixture(%{confirmed: false})
    {:ok, email} = Users.deliver_confirmation_instructions(user, &url/1)
    raw = extract_token(email)

    assert {:ok, confirmed} = Users.confirm_user(raw)
    assert confirmed.confirmed_at
    assert Users.confirm_user(raw) == :error
  end

  test "an expired confirm token fails" do
    user = user_fixture(%{confirmed: false})
    {:ok, email} = Users.deliver_confirmation_instructions(user, &url/1)
    age("confirm", 24 * 7 + 1)
    assert Users.confirm_user(extract_token(email)) == :error
  end

  test "garbage and unknown tokens fail" do
    assert Users.confirm_user("not base64 !!") == :error
    assert Users.confirm_user(Base.url_encode64("x", padding: false)) == :error
    assert Users.get_user_by_reset_password_token("%%%") == nil
    assert Users.get_user_by_reset_password_token(nil) == nil
  end

  test "confirmation is refused for an already confirmed user" do
    user = user_fixture()
    assert Users.deliver_confirmation_instructions(user, &url/1) == {:error, :already_confirmed}
  end

  test "a confirm token cannot be used as a reset token" do
    user = user_fixture(%{confirmed: false})
    {:ok, email} = Users.deliver_confirmation_instructions(user, &url/1)
    assert Users.get_user_by_reset_password_token(extract_token(email)) == nil
  end

  test "reset_user_password/2 sets the password once, rotates the nonce, deletes tokens" do
    user = user_fixture()
    {:ok, email} = Users.deliver_reset_password_instructions(user, &url/1)
    raw = extract_token(email)

    found = Users.get_user_by_reset_password_token(raw)
    assert found.id == user.id

    assert {:ok, updated} = Users.reset_user_password(found, %{password: "brand-new-password-1"})
    assert updated.session_nonce != user.session_nonce
    assert Users.get_user_by_email_and_password(user.email, "brand-new-password-1")
    refute Users.get_user_by_email_and_password(user.email, valid_user_password())
    assert Users.get_user_by_reset_password_token(raw) == nil
    assert Repo.aggregate(UserToken, :count) == 0
  end

  test "reset_user_password/2 enforces the password rules and keeps the token" do
    user = user_fixture()
    {:ok, email} = Users.deliver_reset_password_instructions(user, &url/1)
    assert {:error, changeset} = Users.reset_user_password(user, %{password: "short"})
    assert "should be at least 12 character(s)" in errors_on(changeset).password
    assert Users.get_user_by_reset_password_token(extract_token(email))
  end

  test "an expired reset token fails" do
    user = user_fixture()
    {:ok, email} = Users.deliver_reset_password_instructions(user, &url/1)
    age("reset_password", 2)
    assert Users.get_user_by_reset_password_token(extract_token(email)) == nil
  end
end
