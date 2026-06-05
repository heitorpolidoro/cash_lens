defmodule CashLensWeb.TransactionLive.IndexHandlersTest do
  use CashLensWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  describe "installment linking" do
    test "link_installment then unlink_installment", %{conn: conn} do
      {:ok, group} =
        Installments.create_installment_group(%{
          description_pattern: "LOJA (2x)",
          total_amount: "200.00",
          installments: 2,
          start_date: Date.utc_today()
        })

      tx = transaction_fixture(%{amount: "-100.00", description: "LOJA compra"})

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "link_installment", %{"id" => tx.id, "group_id" => group.id})
      assert render(live) =~ "Vinculado a LOJA (2x)!"
      assert Repo.get!(Transaction, tx.id).installment_group_id == group.id

      render_click(live, "unlink_installment", %{"id" => tx.id})
      assert is_nil(Repo.get!(Transaction, tx.id).installment_group_id)
    end
  end

  describe "transfer pair modal" do
    setup do
      cat = category_fixture(%{name: "Transfer", slug: "transfer"})
      a = account_fixture(%{name: "A"})
      b = account_fixture(%{name: "B"})
      key = Ecto.UUID.generate()

      t1 =
        transaction_fixture(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-03-01]
        })

      t2 =
        transaction_fixture(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-03-01]
        })

      Repo.update_all(from(t in Transaction, where: t.id in [^t1.id, ^t2.id]),
        set: [transfer_key: key]
      )

      %{key: key, t1: t1, t2: t2}
    end

    test "open_transfer_pair shows the linked pair", %{conn: conn, key: key} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      html = render_click(live, "open_transfer_pair", %{"key" => key})
      assert html =~ "desvincular" or html =~ "Desvincular" or html =~ "transfer"
    end

    test "open_transfer_pair with unknown key flashes error", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      render_click(live, "open_transfer_pair", %{"key" => Ecto.UUID.generate()})
      assert render(live) =~ "Par de transferência não encontrado."
    end

    test "unlink_transfer_pair clears the key", %{conn: conn, key: key, t1: t1} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      render_click(live, "unlink_transfer_pair", %{"key" => key})

      assert render(live) =~ "Transferência desvinculada."
      assert is_nil(Repo.get!(Transaction, t1.id).transfer_key)
    end
  end

  describe "bulk selection" do
    test "toggle_bulk_tx and toggle_bulk_all after a bulk suggestion", %{conn: conn} do
      cat = category_fixture(name: "Food")
      tx1 = transaction_fixture(description: "Padaria")
      tx2 = transaction_fixture(description: "Padaria")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      # Categorizing one creates a bulk suggestion for the matching duplicate.
      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      assert render(live) =~ "Categorização em Lote"

      render_click(live, "toggle_bulk_all", %{})
      render_click(live, "toggle_bulk_all", %{})
      render_click(live, "toggle_bulk_tx", %{"id" => tx2.id})

      assert render(live) =~ "Categorização em Lote"
    end
  end

  describe "filters" do
    test "clear_filter resets a single field", %{conn: conn} do
      transaction_fixture(description: "Alvo")
      {:ok, live, _html} = live(conn, ~p"/transactions")

      live |> form("#transaction-filters", %{"search" => "Alvo"}) |> render_change()
      render_click(live, "clear_filter", %{"field" => "search"})

      assert render(live) =~ "Transações"
    end

    test "set_date_range applies date filters", %{conn: conn} do
      transaction_fixture(description: "DataAlvo", date: ~D[2026-03-15])
      {:ok, live, _html} = live(conn, ~p"/transactions")

      html =
        render_hook(live, "set_date_range", %{
          "date_from" => "2026-03-01",
          "date_to" => "2026-03-31"
        })

      assert html =~ "Transações"
    end
  end

  describe "import progress handle_info" do
    test "progress and success messages update the view", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")

      send(live.pid, {:import_file_parsed, 5})
      send(live.pid, {:import_file_done, 5})
      send(live.pid, {:import_success, %{imported: 3, failed: []}})
      assert render(live) =~ "3 transações importadas"
    end

    test "success with failures shows the ignored-lines flash", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")

      send(live.pid, {:import_success, %{imported: 2, failed: [{"linha ruim", "motivo"}]}})
      assert render(live) =~ "linhas ignoradas"
    end
  end

  describe "notes and reimbursement" do
    test "open_notes, save_notes and mark_reimbursable", %{conn: conn} do
      tx = transaction_fixture(%{amount: "-50.00", notes: nil})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "open_notes", %{"id" => tx.id})
      render_click(live, "save_notes", %{"tx_id" => tx.id, "notes" => "minha nota"})
      assert Repo.get!(Transaction, tx.id).notes == "minha nota"

      render_click(live, "mark_reimbursable", %{"id" => tx.id})
      assert Repo.get!(Transaction, tx.id).reimbursement_status == "pending"
    end
  end
end
