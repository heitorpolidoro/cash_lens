defmodule CashLensWeb.Api.BalanceControllerTenancyTest do
  use CashLensWeb.ConnCase, async: false

  import CashLens.AccountingFixtures
  import CashLens.AccountsFixtures

  # The logged-in user (from ConnCase) plays user B; `other` owns the foreign row.
  setup %{user: user} do
    %{a: other} = cross_tenant()
    foreign_account = account_fixture(%{user: other, name: "Foreign account"})
    foreign = balance_fixture(%{user: other, account_id: foreign_account.id})
    mine = balance_fixture(%{user: user})
    {:ok, foreign_account: foreign_account, foreign: foreign, mine: mine}
  end

  test "index lists only the logged-in user's balances", %{conn: conn, mine: mine} do
    conn = get(conn, ~p"/api/balances")
    assert [%{"id" => id}] = json_response(conn, 200)["data"]
    assert id == mine.id
  end

  test "index with a foreign account_id filter is empty", %{
    conn: conn,
    foreign_account: account
  } do
    conn = get(conn, ~p"/api/balances", %{"account_id" => account.id})
    assert json_response(conn, 200)["data"] == []
  end

  test "show answers 404 for another user's balance", %{conn: conn, foreign: foreign} do
    conn = get(conn, ~p"/api/balances/#{foreign.id}")
    assert response(conn, 404) =~ "not found"
    refute conn.resp_body =~ "Foreign account"
  end

  test "show returns the user's own balance", %{conn: conn, mine: mine} do
    conn = get(conn, ~p"/api/balances/#{mine.id}")
    assert json_response(conn, 200)["data"]["id"] == mine.id
  end
end
