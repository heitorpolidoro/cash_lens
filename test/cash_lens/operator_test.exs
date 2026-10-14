defmodule CashLens.OperatorTest do
  use CashLens.DataCase, async: false

  alias CashLens.Operator

  @moduletag :no_current_user

  describe "user!/1" do
    test "returns the user having the given email and pins it" do
      user_fixture()
      target = user_fixture()

      assert Operator.user!(target.email).id == target.id
      assert Repo.current_user_id() == target.id
    end

    test "raises Mix.Error for an unknown email" do
      user_fixture()
      assert_raise Mix.Error, ~r/ghost@example.com/, fn -> Operator.user!("ghost@example.com") end
    end

    test "returns the only user when no email is given" do
      user = user_fixture()
      assert Operator.user!(nil).id == user.id
      assert Operator.user!("").id == user.id
    end

    test "raises Mix.Error when no user exists" do
      assert_raise Mix.Error, ~r/no user exists/, fn -> Operator.user!(nil) end
    end

    test "raises Mix.Error when several users exist and no email is given" do
      user_fixture()
      user_fixture()
      assert_raise Mix.Error, ~r/--user <email>/, fn -> Operator.user!(nil) end
    end
  end

  describe "parse_args/1" do
    test "splits --user from the other arguments" do
      assert Operator.parse_args(["--user", "a@x.com", "/tmp/x"]) == {"a@x.com", ["/tmp/x"]}
      assert Operator.parse_args(["/tmp/x"]) == {nil, ["/tmp/x"]}
    end
  end

  defp user_fixture, do: CashLens.UsersFixtures.user_fixture()
end
