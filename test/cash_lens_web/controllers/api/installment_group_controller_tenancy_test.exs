defmodule CashLensWeb.Api.InstallmentGroupControllerTenancyTest do
  use CashLensWeb.ConnCase, async: false

  alias CashLens.Installments
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Repo
  alias CashLens.Tenancy

  defp create_group(user, pattern) do
    Tenancy.acting_as(user, fn ->
      {:ok, group} =
        Installments.create_installment_group(user, %{
          description_pattern: pattern,
          installments: 4,
          start_date: ~D[2026-06-01],
          total_amount: "400.00"
        })

      Repo.get!(InstallmentGroup, group.id)
    end)
  end

  # The logged-in user (from ConnCase) plays user B; `other` owns the foreign row.
  setup %{user: user} do
    %{a: other} = cross_tenant()
    foreign = create_group(other, "FOREIGN GROUP")
    mine = create_group(user, "MY GROUP")
    {:ok, other: other, foreign: foreign, mine: mine}
  end

  # The foreign row, read back as its owner.
  defp reload_foreign(other, foreign) do
    Tenancy.acting_as(other, fn -> Repo.get!(InstallmentGroup, foreign.id) end)
  end

  test "index lists only the logged-in user's groups", %{conn: conn, mine: mine} do
    conn = get(conn, ~p"/api/installment_groups")
    assert [%{"id" => id}] = json_response(conn, 200)["data"]
    assert id == mine.id
  end

  test "GET answers 404 for another user's group", %{conn: conn, foreign: foreign} do
    conn = get(conn, ~p"/api/installment_groups/#{foreign.id}")
    assert response(conn, 404) =~ "not found"
    refute conn.resp_body =~ "FOREIGN GROUP"
  end

  test "PUT answers 404 for another user's group and leaves it unchanged", %{
    conn: conn,
    other: other,
    foreign: foreign
  } do
    conn =
      put(conn, ~p"/api/installment_groups/#{foreign.id}", %{"description_pattern" => "HIJACKED"})

    assert response(conn, 404) =~ "not found"
    assert reload_foreign(other, foreign) == foreign
  end

  test "DELETE answers 404 for another user's group and leaves it in place", %{
    conn: conn,
    other: other,
    foreign: foreign
  } do
    conn = delete(conn, ~p"/api/installment_groups/#{foreign.id}")
    assert response(conn, 404) =~ "not found"
    assert reload_foreign(other, foreign) == foreign
  end

  test "the user's own group can still be read, updated and deleted", %{conn: conn, mine: mine} do
    assert json_response(get(conn, ~p"/api/installment_groups/#{mine.id}"), 200)["data"]["id"] ==
             mine.id

    conn2 =
      put(conn, ~p"/api/installment_groups/#{mine.id}", %{"description_pattern" => "RENAMED"})

    assert json_response(conn2, 200)["data"]["description_pattern"] == "RENAMED"

    conn3 = delete(conn, ~p"/api/installment_groups/#{mine.id}")
    assert response(conn3, 204)
  end
end
