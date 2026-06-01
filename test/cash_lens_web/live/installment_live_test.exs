defmodule CashLensWeb.InstallmentLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  test "renders the page with no groups", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/installments")
    assert html =~ "Grupos de Parcelamento"
  end

  test "lists active installment groups with progress", %{conn: conn} do
    {:ok, group} =
      Installments.create_installment_group(%{
        description_pattern: "LOJA X (3x)",
        total_amount: "300.00",
        installments: 3,
        start_date: Date.utc_today()
      })

    acc = account_fixture()

    tx = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "LOJA X 1/3"})

    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
      set: [installment_group_id: group.id]
    )

    {:ok, _live, html} = live(conn, ~p"/installments")
    assert html =~ "LOJA X (3x)"
  end

  test "open and close the new-group modal", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")

    render_click(live, "open_modal", %{})
    assert render(live) =~ "installment_group"

    render_click(live, "close_modal", %{})

    refute has_element?(
             live,
             "form#installment-group-form input[name='installment_group[installments]']"
           )
  end

  test "save creates a group", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")

    render_click(live, "open_modal", %{})

    render_submit(live, "save", %{
      "installment_group" => %{
        "description_pattern" => "NOVA LOJA (2x)",
        "total_amount" => "200.00",
        "installments" => "2",
        "start_date" => Date.to_string(Date.utc_today())
      }
    })

    assert render(live) =~ "Grupo de parcelamento criado!"

    assert Enum.any?(
             Installments.list_installment_groups(),
             &(&1.description_pattern == "NOVA LOJA (2x)")
           )
  end

  test "save with invalid data re-renders the form", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")
    render_click(live, "open_modal", %{})

    render_submit(live, "save", %{
      "installment_group" => %{
        "description_pattern" => "",
        "installments" => "",
        "start_date" => ""
      }
    })

    assert Installments.list_installment_groups() == []
  end

  test "delete removes a group", %{conn: conn} do
    {:ok, group} =
      Installments.create_installment_group(%{
        description_pattern: "DEL (2x)",
        total_amount: "100.00",
        installments: 2,
        start_date: Date.utc_today()
      })

    {:ok, live, _html} = live(conn, ~p"/installments")
    render_click(live, "delete", %{"id" => group.id})

    assert Installments.list_installment_groups() == []
  end

  test "detect_installments scans and groups", %{conn: conn} do
    acc = account_fixture()

    transaction_fixture(%{
      account_id: acc.id,
      amount: "-50.00",
      description: "EC LOJA PARC 01/02 BR",
      date: ~D[2026-01-10]
    })

    transaction_fixture(%{
      account_id: acc.id,
      amount: "-50.00",
      description: "EC LOJA PARC 02/02 BR",
      date: ~D[2026-01-10]
    })

    {:ok, live, _html} = live(conn, ~p"/installments")
    html = render_click(live, "detect_installments", %{})

    assert html =~ "detectada(s)"
  end
end
