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

  defp unmatched_transaction(attrs) do
    tx = transaction_fixture(attrs)
    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [transfer_key: nil])
    Repo.get!(Transaction, tx.id)
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

  defp linked_pair(cat, a, b, date) do
    key = Ecto.UUID.generate()

    l1 =
      transaction_fixture(%{account_id: a.id, category_id: cat.id, amount: "-40.00", date: date})

    l2 =
      transaction_fixture(%{account_id: b.id, category_id: cat.id, amount: "40.00", date: date})

    Repo.update_all(from(t in Transaction, where: t.id in [^l1.id, ^l2.id]),
      set: [transfer_key: key]
    )

    {key, Repo.get!(Transaction, l1.id), Repo.get!(Transaction, l2.id)}
  end

  describe "page header" do
    test "carries the transfer rules link as its only action", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/transfers")

      assert html =~ "Central de Transferências"

      assert has_element?(
               live,
               "#transfers-header a[href='/admin/transfer_rules']",
               "Regras de Transferência"
             )

      assert live
             |> element("#transfers-header")
             |> render()
             |> then(&Regex.scan(~r/<a /, &1))
             |> length() == 1

      refute has_element?(live, "#transfers-header button")
    end

    test "does not expose the reapply rules action", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/transfers")

      refute html =~ "reapply_rules"
      refute html =~ "Reaplicar Regras"
      refute has_element?(live, "[phx-click='reapply_rules']")
    end
  end

  describe "pending pairs indicator" do
    test "counts unmatched transfer transactions", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      suggested_pair(cat, a, b, ~D[2026-03-01])

      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-77.00",
        date: ~D[2026-03-10]
      })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      card = live |> element("#pending-pairs-card") |> render()
      assert card =~ "Pares Pendentes"
      assert card =~ "3 transações"
    end

    test "is the only indicator card on the page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/transfers")

      assert html =~ "Pares Pendentes"
      refute html =~ "Movimentado"
      refute html =~ "movimentado no mês"
      refute html =~ "Neutralidade"
      refute html =~ "Bitributação"
      refute html =~ "bitributação"
    end
  end

  describe "tabs" do
    test "defaults to the pending tab", %{conn: conn, transfer_cat: cat, acc_a: a, acc_b: b} do
      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-77.00",
        date: ~D[2026-03-10]
      })

      linked_pair(cat, a, b, ~D[2026-04-01])

      {:ok, live, _html} = live(conn, ~p"/transfers")

      assert has_element?(live, "#pending-transfers")
      refute has_element?(live, "#reconciled-transfers")
    end

    test "?tab=history shows the reconciled history", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      linked_pair(cat, a, b, ~D[2026-04-01])

      {:ok, live, html} = live(conn, ~p"/transfers?tab=history")

      assert html =~ "Histórico Conciliado"
      assert has_element?(live, "#reconciled-transfers")
      refute has_element?(live, "#pending-transfers")
      assert render(live) =~ "R$ 40,00"
    end

    test "switching tabs patches the query parameter", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      linked_pair(cat, a, b, ~D[2026-04-01])

      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-77.00",
        date: ~D[2026-03-10]
      })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      html = live |> element("#tab-history") |> render_click()
      assert html =~ "Histórico Conciliado"
      assert has_element?(live, "#reconciled-transfers")
      assert_patched(live, "/transfers?tab=history")

      live |> element("#tab-pending") |> render_click()
      assert has_element?(live, "#pending-transfers")
      assert_patched(live, "/transfers?tab=pending")
    end
  end

  describe "suggested pairs" do
    test "lists a pair whose dates are within three days", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-150.00",
        date: ~D[2026-03-01]
      })

      unmatched_transaction(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "150.00",
        date: ~D[2026-03-03]
      })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      assert has_element?(live, "#transfer-suggestions")
      html = render(live)
      assert html =~ "R$ 150,00"
      assert html =~ "BB - Conta A"
      assert html =~ "BB - Conta B"
      assert html =~ "Confirmar Par"
    end

    test "confirm_pair links the pair and sets the transfer_key", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      {out, inc} = suggested_pair(cat, a, b, ~D[2026-03-05])

      {:ok, live, _html} = live(conn, ~p"/transfers")

      html =
        live
        |> element("button[phx-click='confirm_pair'][phx-value-a='#{out.id}']")
        |> render_click()

      assert html =~ "Transferência vinculada!"

      key = Repo.get!(Transaction, out.id).transfer_key
      refute is_nil(key)
      assert Repo.get!(Transaction, inc.id).transfer_key == key
    end

    test "confirm_all links every suggestion", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      suggested_pair(cat, a, b, ~D[2026-03-06])

      {:ok, live, _html} = live(conn, ~p"/transfers")

      html = live |> element("button[phx-click='confirm_all']") |> render_click()

      assert html =~ "vinculadas!"
      assert Transactions.list_transfer_suggestions() == []
    end
  end

  describe "manual link modal" do
    test "lists candidates with the amount and day differences", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-05-01]
        })

      unmatched_transaction(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "99.50",
        date: ~D[2026-05-04]
      })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      live
      |> element("button[phx-click='open_link_modal'][phx-value-id='#{origin.id}']")
      |> render_click()

      assert has_element?(live, "#manual-link-modal")
      modal = live |> element("#manual-link-modal") |> render()
      assert modal =~ "R$ 0,50"
      assert modal =~ "3 dias"
    end

    test "link_candidate links the chosen candidate", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-05-01]
        })

      candidate =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-05-09]
        })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      live
      |> element("button[phx-click='open_link_modal'][phx-value-id='#{origin.id}']")
      |> render_click()

      html =
        live
        |> element("button[phx-click='link_candidate'][phx-value-id='#{candidate.id}']")
        |> render_click()

      assert html =~ "Transferência vinculada!"
      refute has_element?(live, "#manual-link-modal")

      key = Repo.get!(Transaction, origin.id).transfer_key
      refute is_nil(key)
      assert Repo.get!(Transaction, candidate.id).transfer_key == key
    end
  end

  describe "mirror creation" do
    test "creates the counterpart transaction on the chosen account", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-321.00",
          date: ~D[2026-06-01]
        })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      live
      |> element("button[phx-click='open_mirror_modal'][phx-value-id='#{origin.id}']")
      |> render_click()

      assert has_element?(live, "#mirror-modal")

      html =
        live
        |> form("#mirror-form", %{"account_id" => b.id})
        |> render_submit()

      assert html =~ "Transação espelho criada"

      key = Repo.get!(Transaction, origin.id).transfer_key
      refute is_nil(key)

      mirror = Repo.one!(from t in Transaction, where: t.account_id == ^b.id)
      assert mirror.transfer_key == key
      assert Decimal.equal?(mirror.amount, Decimal.new("321.00"))
    end

    test "reports an invalid destination account", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-321.00",
          date: ~D[2026-06-01]
        })

      {:ok, live, _html} = live(conn, ~p"/transfers")

      live
      |> element("button[phx-click='open_mirror_modal'][phx-value-id='#{origin.id}']")
      |> render_click()

      # The select never offers the origin account, so the guard is exercised by
      # pushing the event straight at the LiveView.
      html = render_submit(live, "create_mirror", %{"account_id" => a.id})

      assert html =~ "mesma conta"
      assert is_nil(Repo.get!(Transaction, origin.id).transfer_key)
    end
  end

  describe "reconciled history" do
    test "shows the account flow and allows unlinking", %{
      conn: conn,
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      {key, l1, _l2} = linked_pair(cat, a, b, ~D[2026-04-02])

      {:ok, live, html} = live(conn, ~p"/transfers?tab=history")

      assert html =~ "BB - Conta A"
      assert html =~ "BB - Conta B"

      result =
        live
        |> element("button[phx-click='unlink'][phx-value-key='#{key}']")
        |> render_click()

      assert result =~ "desvinculada"
      assert is_nil(Repo.get!(Transaction, l1.id).transfer_key)
    end
  end
end
