defmodule CashLensWeb.Api.TransactionControllerTenancyTest do
  use CashLensWeb.ConnCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Tenancy
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  # The logged-in user (from ConnCase) plays user B; `other` owns the foreign row.
  setup %{user: user} do
    %{a: other} = cross_tenant()
    foreign_account = account_fixture(%{user: other, name: "Foreign account"})

    foreign =
      transaction_fixture(%{
        user: other,
        account_id: foreign_account.id,
        description: "Foreign purchase",
        amount: "-42.00"
      })

    mine = transaction_fixture(%{user: user, description: "My purchase"})
    {:ok, other: other, foreign_account: foreign_account, foreign: foreign, mine: mine}
  end

  # The foreign row, read back as its owner.
  defp reload_foreign(other, foreign) do
    Tenancy.acting_as(other, fn -> Repo.get!(Transaction, foreign.id) end)
  end

  test "index lists only the logged-in user's transactions", %{conn: conn, mine: mine} do
    conn = get(conn, ~p"/api/transactions")
    assert [%{"id" => id}] = json_response(conn, 200)["data"]
    assert id == mine.id
    assert json_response(conn, 200)["meta"]["total"] == 1
  end

  test "index with a foreign account_id or category_id filter is empty", %{
    conn: conn,
    foreign_account: account
  } do
    conn = get(conn, ~p"/api/transactions", %{"account_id" => account.id})
    assert json_response(conn, 200)["data"] == []
  end

  test "GET answers 404 for another user's transaction", %{conn: conn, foreign: foreign} do
    conn = get(conn, ~p"/api/transactions/#{foreign.id}")
    assert response(conn, 404) =~ "not found"
    refute conn.resp_body =~ "Foreign purchase"
  end

  test "PUT answers 404 for another user's transaction and leaves it unchanged", %{
    conn: conn,
    other: other,
    foreign: foreign
  } do
    conn = put(conn, ~p"/api/transactions/#{foreign.id}", %{"description" => "hijacked"})
    assert response(conn, 404) =~ "not found"
    assert reload_foreign(other, foreign) == foreign
  end

  test "DELETE answers 404 for another user's transaction and leaves it in place", %{
    conn: conn,
    other: other,
    foreign: foreign
  } do
    conn = delete(conn, ~p"/api/transactions/#{foreign.id}")
    assert response(conn, 404) =~ "not found"
    assert reload_foreign(other, foreign) == foreign
  end

  test "the user's own transaction can still be read, updated and deleted", %{
    conn: conn,
    user: user,
    mine: mine
  } do
    assert json_response(get(conn, ~p"/api/transactions/#{mine.id}"), 200)["data"]["id"] ==
             mine.id

    updated = put(conn, ~p"/api/transactions/#{mine.id}", %{"description" => "renamed"})
    assert json_response(updated, 200)["data"]["description"] == "renamed"

    assert response(delete(conn, ~p"/api/transactions/#{mine.id}"), 204)
    assert Transactions.get_transaction(user, mine.id) == nil
  end

  test "updating the category to another user's category is a 422", %{
    conn: conn,
    other: other,
    mine: mine
  } do
    category = CashLens.CategoriesFixtures.category_fixture(%{user: other, name: "Foreign cat"})

    conn = put(conn, ~p"/api/transactions/#{mine.id}", %{"category_id" => category.id})
    assert %{"category_id" => _} = json_response(conn, 422)["error"]
  end
end
