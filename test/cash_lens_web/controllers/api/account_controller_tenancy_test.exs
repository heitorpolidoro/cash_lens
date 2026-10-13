defmodule CashLensWeb.Api.AccountControllerTenancyTest do
  use CashLensWeb.ConnCase, async: false

  import CashLens.AccountsFixtures

  alias CashLens.Accounts

  # The logged-in user (from ConnCase) plays user B; `other` owns the foreign row.
  setup %{user: user} do
    %{a: other} = cross_tenant()
    foreign = account_fixture(%{user: other, name: "Foreign account"})
    mine = account_fixture(%{user: user, name: "My account"})
    {:ok, other: other, foreign: foreign, mine: mine}
  end

  test "index lists only the logged-in user's accounts", %{conn: conn, mine: mine} do
    conn = get(conn, ~p"/api/accounts")
    assert [%{"id" => id}] = json_response(conn, 200)["data"]
    assert id == mine.id
  end

  test "show answers 404 for another user's account", %{conn: conn, foreign: foreign} do
    conn = get(conn, ~p"/api/accounts/#{foreign.id}")
    assert json_response(conn, 404)
    refute conn.resp_body =~ "Foreign account"
  end

  test "update answers 404 and leaves the account unchanged", %{
    conn: conn,
    other: other,
    foreign: foreign
  } do
    conn = put(conn, ~p"/api/accounts/#{foreign.id}", %{"name" => "hijacked"})
    assert json_response(conn, 404)

    CashLens.Tenancy.acting_as(other, fn ->
      assert Accounts.get_account!(other, foreign.id) |> Map.get(:name) == "Foreign account"
    end)
  end

  test "delete answers 404 and keeps the account", %{conn: conn, other: other, foreign: foreign} do
    conn = delete(conn, ~p"/api/accounts/#{foreign.id}")
    assert json_response(conn, 404)

    CashLens.Tenancy.acting_as(other, fn ->
      assert Accounts.get_account!(other, foreign.id).id == foreign.id
    end)
  end

  test "create ignores a user_id and owns the account as the logged-in user", %{
    conn: conn,
    user: user,
    other: other
  } do
    attrs = %{
      "name" => "Created",
      "bank" => "bank",
      "balance" => "1",
      "color" => "c",
      "icon" => "i",
      "user_id" => other.id
    }

    conn = post(conn, ~p"/api/accounts", attrs)
    assert %{"id" => id} = json_response(conn, 201)["data"]
    assert Accounts.get_account!(user, id).user_id == user.id
  end
end
