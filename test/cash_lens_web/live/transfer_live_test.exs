defmodule CashLensWeb.TransferLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  setup do
    transfer_cat = category_fixture(%{name: "Transfer", slug: "transfer"})
    acc_a = account_fixture(%{name: "Conta A", bank: "BB"})
    acc_b = account_fixture(%{name: "Conta B", bank: "BB"})
    %{transfer_cat: transfer_cat, acc_a: acc_a, acc_b: acc_b}
  end

  defp suggested_pair(cat, a, b, date) do
    out =
      transaction_fixture(%{account_id: a.id, category_id: cat.id, amount: "-100.00", date: date})

    inc =
      transaction_fixture(%{account_id: b.id, category_id: cat.id, amount: "100.00", date: date})

    # Clear any auto-linking so they show up as suggestions.
    Repo.update_all(from(t in Transaction, where: t.id in [^out.id, ^inc.id]),
      set: [transfer_key: nil]
    )

    {Repo.get!(Transaction, out.id), Repo.get!(Transaction, inc.id)}
  end

  test "renders the empty state", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/transfers")
    assert html =~ "Transferências"
    assert html =~ "Pares Sugeridos"
    assert html =~ "Sem sugestões"
  end

  test "lists suggestions, unmatched singles and linked pairs", %{
    conn: conn,
    transfer_cat: cat,
    acc_a: a,
    acc_b: b
  } do
    suggested_pair(cat, a, b, ~D[2026-03-01])

    # Unmatched single: a transfer with no opposite.
    unmatched = transaction_fixture(%{account_id: a.id, category_id: cat.id, amount: "-77.00"})

    Repo.update_all(from(t in Transaction, where: t.id == ^unmatched.id),
      set: [transfer_key: nil]
    )

    # Linked pair.
    key = Ecto.UUID.generate()

    l1 =
      transaction_fixture(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-40.00",
        date: ~D[2026-04-01]
      })

    l2 =
      transaction_fixture(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "40.00",
        date: ~D[2026-04-01]
      })

    Repo.update_all(from(t in Transaction, where: t.id in [^l1.id, ^l2.id]),
      set: [transfer_key: key]
    )

    {:ok, _live, html} = live(conn, ~p"/transfers")

    assert html =~ "Pares Sugeridos"
    assert html =~ "Sem Par Encontrado"
    assert html =~ "Transferências Vinculadas"
    assert html =~ "Confirmar Todos"
  end

  test "confirm_pair links a suggested pair", %{conn: conn, transfer_cat: cat, acc_a: a, acc_b: b} do
    {out, inc} = suggested_pair(cat, a, b, ~D[2026-03-05])

    {:ok, live, _html} = live(conn, ~p"/transfers")
    render_click(live, "confirm_pair", %{"a" => out.id, "b" => inc.id})

    assert render(live) =~ "Transferência vinculada!"

    assert Repo.get!(Transaction, out.id).transfer_key ==
             Repo.get!(Transaction, inc.id).transfer_key

    refute is_nil(Repo.get!(Transaction, out.id).transfer_key)
  end

  test "confirm_all links every suggestion", %{conn: conn, transfer_cat: cat, acc_a: a, acc_b: b} do
    suggested_pair(cat, a, b, ~D[2026-03-06])

    {:ok, live, _html} = live(conn, ~p"/transfers")
    render_click(live, "confirm_all", %{})

    assert render(live) =~ "vinculadas!"
    assert Transactions.list_transfer_suggestions() == []
  end

  test "open_transfer_link opens the modal with candidates", %{
    conn: conn,
    transfer_cat: cat,
    acc_a: a,
    acc_b: b
  } do
    origin =
      transaction_fixture(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-55.00",
        date: ~D[2026-05-01]
      })

    Repo.update_all(from(t in Transaction, where: t.id == ^origin.id), set: [transfer_key: nil])

    _candidate =
      transaction_fixture(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "55.00",
        date: ~D[2026-05-02]
      })

    {:ok, live, _html} = live(conn, ~p"/transfers")
    render_click(live, "open_transfer_link", %{"id" => origin.id})

    assert has_element?(live, "#transfer-modal")
  end

  test "unlink removes a linked pair", %{conn: conn, transfer_cat: cat, acc_a: a, acc_b: b} do
    key = Ecto.UUID.generate()

    l1 =
      transaction_fixture(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-40.00",
        date: ~D[2026-04-02]
      })

    l2 =
      transaction_fixture(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "40.00",
        date: ~D[2026-04-02]
      })

    Repo.update_all(from(t in Transaction, where: t.id in [^l1.id, ^l2.id]),
      set: [transfer_key: key]
    )

    {:ok, live, _html} = live(conn, ~p"/transfers")
    render_click(live, "unlink", %{"key" => key})

    assert render(live) =~ "desvinculada"
    assert is_nil(Repo.get!(Transaction, l1.id).transfer_key)
  end

  test "handle_info messages close the modal and flash", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/transfers")

    send(live.pid, :close_transfer_modal)
    send(live.pid, {:transfer_linked, "Par criado!"})

    assert render(live) =~ "Par criado!"
  end
end
