defmodule CashLensWeb.Api.CategoryControllerTenancyTest do
  use CashLensWeb.ConnCase, async: false

  import CashLens.CategoriesFixtures

  alias CashLens.Categories

  # The logged-in user (from ConnCase) plays user B; `other` owns the foreign row.
  setup %{user: user} do
    %{a: other} = cross_tenant()
    foreign = category_fixture(%{user: other, name: "Foreign category"})
    mine = category_fixture(%{user: user, name: "My category"})
    {:ok, other: other, foreign: foreign, mine: mine}
  end

  test "index lists only the logged-in user's categories", %{conn: conn, mine: mine} do
    conn = get(conn, ~p"/api/categories")
    assert [%{"id" => id}] = json_response(conn, 200)["data"]
    assert id == mine.id
  end

  test "show answers 404 for another user's category", %{conn: conn, foreign: foreign} do
    conn = get(conn, ~p"/api/categories/#{foreign.id}")
    assert json_response(conn, 404)
    refute conn.resp_body =~ "Foreign category"
  end

  test "update answers 404 and leaves the category unchanged", %{
    conn: conn,
    other: other,
    foreign: foreign
  } do
    conn = put(conn, ~p"/api/categories/#{foreign.id}", %{"name" => "hijacked"})
    assert json_response(conn, 404)

    CashLens.Tenancy.acting_as(other, fn ->
      assert Categories.get_category!(other, foreign.id).name == "Foreign category"
    end)
  end

  test "delete answers 404 and keeps the category", %{conn: conn, other: other, foreign: foreign} do
    conn = delete(conn, ~p"/api/categories/#{foreign.id}")
    assert json_response(conn, 404)

    CashLens.Tenancy.acting_as(other, fn ->
      assert Categories.get_category!(other, foreign.id).id == foreign.id
    end)
  end

  test "create ignores a user_id and owns the category as the logged-in user", %{
    conn: conn,
    user: user,
    other: other
  } do
    conn = post(conn, ~p"/api/categories", %{"name" => "Created", "user_id" => other.id})
    assert %{"id" => id} = json_response(conn, 201)["data"]
    assert Categories.get_category!(user, id).user_id == user.id
  end

  test "create rejects another user's category as parent", %{conn: conn, foreign: foreign} do
    conn = post(conn, ~p"/api/categories", %{"name" => "Child", "parent_id" => foreign.id})
    assert %{"error" => %{"parent_id" => _}} = json_response(conn, 422)
  end
end
