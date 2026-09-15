defmodule CashLensWeb.ReimbursementLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  describe "Index" do
    test "lists reimbursements", %{conn: conn} do
      acc = account_fixture()

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "pending",
        amount: "-100.00",
        description: "Lunch for team"
      })

      {:ok, _index_live, html} = live(conn, ~p"/reimbursements")

      assert html =~ "Central de Reembolsos"
      assert html =~ "Lunch for team"
    end

    test "toggles selection of a reimbursement expense", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-100.00",
          description: "Lunch for team"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Initially not selected
      refute render(index_live) =~ "1 selecionado"

      # Select
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      assert render(index_live) =~ "1 selecionado"
      assert render(index_live) =~ "100,00"

      # Deselect
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      refute render(index_live) =~ "1 selecionado"
    end

    test "clears selection of reimbursement expenses", %{conn: conn} do
      acc = account_fixture()

      tx1 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-100.00",
          description: "Lunch 1"
        })

      tx2 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-50.00",
          description: "Lunch 2"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Select both
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx1.id}']")
      |> render_click()

      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx2.id}']")
      |> render_click()

      assert render(index_live) =~ "2 selecionados"

      # Clear
      index_live
      |> element("button[phx-click='clear_selection']")
      |> render_click()

      refute render(index_live) =~ "Total Selecionado"
    end

    test "marks a reimbursement as requested", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-120.50",
          description: "Pending item"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      html =
        index_live
        |> element("button[phx-click='mark_requested'][phx-value-id='#{tx.id}']")
        |> render_click()

      assert html =~ "Solicitado"
      assert CashLens.Transactions.get_transaction!(tx.id).reimbursement_status == "requested"
    end

    test "unlinks a reimbursement", %{conn: conn} do
      acc = account_fixture()
      link_key = Ecto.UUID.generate()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "paid",
          reimbursement_link_key: link_key,
          amount: "-100.00",
          description: "Paid expense"
        })

      _credit =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "paid",
          reimbursement_link_key: link_key,
          amount: "100.00",
          description: "Credit"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements?tab=linked")

      index_live
      |> element(
        "button[phx-click='confirm_unlink_reimbursement'][phx-value-link-key='#{link_key}']"
      )
      |> render_click()

      index_live
      |> element("button", "Sim, Desvincular")
      |> render_click()

      assert render(index_live) =~ "desvinculado com sucesso"
      updated = CashLens.Transactions.get_transaction!(expense.id)
      assert is_nil(updated.reimbursement_link_key)
    end

    test "opens batch linker and searches", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-50.00",
          description: "Batch item",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "50.00",
          description: "Batch credit",
          date: ~D[2026-03-20]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      index_live |> element("button[phx-click='open_batch_linker']") |> render_click()
      assert render(index_live) =~ "Vincular Crédito de Reembolso"
      assert render(index_live) =~ credit.description

      render_hook(index_live, "linker_search_change", %{"value" => "Batch"})
      assert render(index_live) =~ "Batch credit"

      render_click(index_live, "close_modal", %{})
      # After close, modal content (not the header button) is gone
      refute render(index_live) =~ "Selecione um ou mais créditos"
    end

    test "sort comparison: exact amount match ranks first", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-75.00",
          description: "Expense 75",
          date: ~D[2026-02-23]
        })

      credit_exact =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "75.00",
          description: "Exact match",
          date: ~D[2026-03-20]
        })

      _credit_other =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "100.00",
          description: "Other amount",
          date: ~D[2026-03-20]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      html = render(index_live)
      assert html =~ "Exact match"

      # Selecting the exact-amount credit reveals the perfect-match indicator
      render_click(index_live, "toggle_credit", %{"credit-id" => credit_exact.id})
      assert render(index_live) =~ "Match Perfeito!"
    end

    test "links an expense with a credit", %{conn: conn} do
      acc = account_fixture()
      cat = category_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-150.00",
          description: "Travel expense",
          category_id: cat.id,
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "150.00",
          description: "Company refund",
          category_id: cat.id,
          date: ~D[2026-03-20]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Click to link single expense
      index_live
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      # Now the modal is open, we can see the credit
      assert render(index_live) =~ "Company refund"

      # Selecting the matching credit reveals the perfect-match indicator
      render_click(index_live, "toggle_credit", %{"credit-id" => credit.id})
      assert render(index_live) =~ "Match Perfeito!"

      # Confirm link
      index_live
      |> element("button[phx-click='confirm_link']")
      |> render_click()

      assert render(index_live) =~ "Reembolso vinculado com sucesso!"

      updated_expense = CashLens.Transactions.get_transaction!(expense.id)
      assert updated_expense.reimbursement_status == "paid"
      assert updated_expense.reimbursement_link_key != nil

      updated_credit = CashLens.Transactions.get_transaction!(credit.id)
      assert updated_credit.reimbursement_status == "paid"
      assert updated_credit.reimbursement_link_key == updated_expense.reimbursement_link_key
    end

    test "confirms a suggested reimbursement pair", %{conn: conn} do
      acc = account_fixture()
      cat = category_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-45.00",
          description: "Suggest expense",
          category_id: cat.id,
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "45.00",
          description: "Suggest credit",
          category_id: cat.id,
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "Conciliação Automática Sugerida"
      assert render(index_live) =~ "Suggest expense"
      assert render(index_live) =~ "Suggest credit"

      index_live
      |> element(
        "button[phx-click='confirm_pair'][phx-value-a='#{expense.id}'][phx-value-b='#{credit.id}']"
      )
      |> render_click()

      assert render(index_live) =~ "Reembolso vinculado com sucesso!"
      assert CashLens.Transactions.get_transaction!(expense.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(credit.id).reimbursement_status == "paid"
    end

    test "shows category reconcile select modal when neither has category", %{conn: conn} do
      acc = account_fixture()
      cat = category_fixture(%{name: "Alimentação", slug: "alimentacao"})

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-50.00",
          description: "No cat expense",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "50.00",
          description: "No cat credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Click confirm_pair -> should show the select reconcile modal
      index_live
      |> element(
        "button[phx-click='confirm_pair'][phx-value-a='#{expense.id}'][phx-value-b='#{credit.id}']"
      )
      |> render_click()

      html = render(index_live)
      assert html =~ "Conciliar Categoria"
      assert html =~ "Nenhuma das transações possui categoria."

      # Submit the form with selected category
      index_live
      |> form("#reconcile-modal form", %{category_id: cat.id})
      |> render_submit()

      assert render(index_live) =~ "Reembolso vinculado com sucesso!"
      assert CashLens.Transactions.get_transaction!(expense.id).category_id == cat.id
      assert CashLens.Transactions.get_transaction!(credit.id).category_id == cat.id
    end

    test "shows category reconcile buttons modal when both have different categories", %{
      conn: conn
    } do
      acc = account_fixture()
      cat_a = category_fixture(%{name: "Saúde", slug: "saude"})
      cat_b = category_fixture(%{name: "Lazer", slug: "lazer"})

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-70.00",
          description: "Saude expense",
          category_id: cat_a.id,
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "70.00",
          description: "Lazer credit",
          category_id: cat_b.id,
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Click confirm_pair -> should show the buttons reconcile modal
      index_live
      |> element(
        "button[phx-click='confirm_pair'][phx-value-a='#{expense.id}'][phx-value-b='#{credit.id}']"
      )
      |> render_click()

      html = render(index_live)
      assert html =~ "Conciliar Categoria"
      assert html =~ "Ambas as transações possuem categorias diferentes."
      assert html =~ "Usar: Saúde"
      assert html =~ "Usar: Lazer"

      # Click to use category A (Saúde)
      index_live
      |> element(
        "button[phx-click='confirm_reconcile_button'][phx-value-category-id='#{cat_a.id}']"
      )
      |> render_click()

      assert render(index_live) =~ "Reembolso vinculado com sucesso!"
      assert CashLens.Transactions.get_transaction!(expense.id).category_id == cat_a.id
      assert CashLens.Transactions.get_transaction!(credit.id).category_id == cat_a.id
    end

    test "confirms all suggested reimbursement pairs", %{conn: conn} do
      acc = account_fixture()

      expense1 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-60.00",
          description: "Suggest expense 1",
          date: ~D[2026-02-23]
        })

      credit1 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "60.00",
          description: "Suggest credit 1",
          date: ~D[2026-02-24]
        })

      expense2 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-80.00",
          description: "Suggest expense 2",
          date: ~D[2026-02-23]
        })

      credit2 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "80.00",
          description: "Suggest credit 2",
          date: ~D[2026-02-25]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "Confirmar Todos"

      index_live
      |> element("button[phx-click='confirm_all_suggestions']")
      |> render_click()

      index_live
      |> element("#confirm-modal button.btn-primary")
      |> render_click()

      assert render(index_live) =~ "2 reembolsos vinculados com sucesso!"
      assert CashLens.Transactions.get_transaction!(expense1.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(credit1.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(expense2.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(credit2.id).reimbursement_status == "paid"
    end

    test "ignores suggestions from accounts that do not accept import", %{conn: conn} do
      acc_no_import = account_fixture(%{accepts_import: false})
      acc_import = account_fixture(%{accepts_import: true})

      _expense =
        transaction_fixture(%{
          account_id: acc_no_import.id,
          reimbursement_status: "pending",
          amount: "-35.00",
          description: "No import expense",
          date: ~D[2026-02-23]
        })

      _credit =
        transaction_fixture(%{
          account_id: acc_import.id,
          amount: "35.00",
          description: "Import credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      refute render(index_live) =~ "Conciliação Automática Sugerida"
      refute render(index_live) =~ "Confirmar"
    end

    test "ignores suggestions where the expense is categorized as transfer", %{conn: conn} do
      acc = account_fixture()
      category = CashLens.CategoriesFixtures.category_fixture(%{name: "Transfer"})

      _expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-40.00",
          description: "Transfer expense",
          date: ~D[2026-02-23],
          category_id: category.id
        })

      _credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "40.00",
          description: "Reimbursement credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      refute render(index_live) =~ "Conciliação Automática Sugerida"
      refute render(index_live) =~ "Confirmar"
    end

    test "sorts unmatched reimbursement expenses in ascending order by date", %{conn: conn} do
      acc = account_fixture()

      _expense_middle =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-10.00",
          description: "Middle Expense",
          date: ~D[2026-02-20]
        })

      _expense_earliest =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-20.00",
          description: "Earliest Expense",
          date: ~D[2026-02-15]
        })

      _expense_latest =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-30.00",
          description: "Latest Expense",
          date: ~D[2026-02-25]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")
      html = render(index_live)

      # The order should be Earliest Expense, then Middle Expense, then Latest Expense
      assert html =~ ~r/Earliest Expense.*Middle Expense.*Latest Expense/s
    end

    test "suggests reimbursement pairs even if neither transaction has reimbursement_status set",
         %{conn: conn} do
      acc = account_fixture()

      _expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: nil,
          amount: "-22.75",
          description: "Anuidade",
          date: ~D[2025-11-25]
        })

      _credit =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: nil,
          amount: "22.75",
          description: "Desconto Anuidade",
          date: ~D[2025-11-25]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")
      html = render(index_live)

      assert html =~ "1 par encontrado"
      assert html =~ "Anuidade"
      assert html =~ "Desconto Anuidade"
    end

    test "rejecting/ignoring a suggested reimbursement pair", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Reimburse expense",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "50.00",
          description: "Reimburse credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "1 par encontrado"

      # Click "Ignorar"
      index_live
      |> element(
        "button[phx-click='confirm_reject_pair'][phx-value-a='#{expense.id}'][phx-value-b='#{credit.id}']"
      )
      |> render_click()

      # Click "Sim, Ignorar" inside the modal
      index_live
      |> element("button", "Sim, Ignorar")
      |> render_click()

      assert render(index_live) =~ "Sugestão de reembolso ignorada."
      refute render(index_live) =~ "Conciliação Automática Sugerida"
    end
  end

  describe "Index — ciclo de vida" do
    test "renders the three lifecycle cards in chronological order", %{conn: conn} do
      acc = account_fixture()
      link_key = Ecto.UUID.generate()

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "pending",
        amount: "-600.00",
        description: "Consulta Dr. Roberto"
      })

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "requested",
        amount: "-1850.00",
        description: "Exames laboratoriais"
      })

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        amount: "-300.00",
        description: "Fisioterapia",
        date: Date.utc_today()
      })

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        amount: "300.00",
        description: "PIX Reembolso",
        date: Date.utc_today()
      })

      {:ok, _live, html} = live(conn, ~p"/reimbursements")

      assert html =~ "Central de Reembolsos"

      idx_to_request = :binary.match(html, "1. A Solicitar") |> elem(0)
      idx_requested = :binary.match(html, "2. Solicitado") |> elem(0)
      idx_received = :binary.match(html, "3. Recebidos") |> elem(0)

      assert idx_to_request < idx_requested
      assert idx_requested < idx_received

      assert html =~ "Ação Necessária"
      assert html =~ "Em Análise"
      assert html =~ "Últimos 12 meses"

      assert html =~ "600,00"
      assert html =~ "1.850,00"
      assert html =~ "300,00"
    end

    test "received metric only counts credits compensated in the last 12 months", %{conn: conn} do
      acc = account_fixture()
      recent_key = Ecto.UUID.generate()
      old_key = Ecto.UUID.generate()

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "paid",
        reimbursement_link_key: recent_key,
        amount: "111.00",
        description: "Credito recente",
        date: Date.utc_today()
      })

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "paid",
        reimbursement_link_key: old_key,
        amount: "999.00",
        description: "Credito antigo",
        date: Date.add(Date.utc_today(), -400)
      })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")

      assert render(live_view) =~ "111,00"
      refute render(live_view) =~ "999,00"
    end

    test "switches between A Receber and Histórico Vinculado tabs", %{conn: conn} do
      acc = account_fixture()
      link_key = Ecto.UUID.generate()

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "pending",
        amount: "-70.00",
        description: "Despesa em aberto"
      })

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        amount: "-80.00",
        description: "Despesa conciliada"
      })

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        amount: "80.00",
        description: "Credito conciliado"
      })

      {:ok, live_view, html} = live(conn, ~p"/reimbursements")

      assert html =~ "Despesa em aberto"
      refute html =~ "Despesa conciliada"

      linked_html =
        live_view
        |> element("a[href='/reimbursements?tab=linked']")
        |> render_click()

      assert linked_html =~ "Despesa conciliada"
      assert linked_html =~ "Credito conciliado"
      refute linked_html =~ "Despesa em aberto"

      pending_html =
        live_view
        |> element("a[href='/reimbursements?tab=pending']")
        |> render_click()

      assert pending_html =~ "Despesa em aberto"
      refute pending_html =~ "Despesa conciliada"
    end

    test "statement modal filters candidates by description and adds one in a single click",
         %{conn: conn} do
      acc = account_fixture()

      candidate =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-350.00",
          description: "Exame de Sangue Fleury",
          date: Date.utc_today()
        })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-120.00",
        description: "Almoco Reuniao Externa",
        date: Date.utc_today()
      })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")

      html =
        live_view |> element("button[phx-click='open_statement_modal']") |> render_click()

      assert html =~ "Marcar Despesa como Reembolsável"
      assert html =~ "Exame de Sangue Fleury"
      assert html =~ "Almoco Reuniao Externa"

      filtered = render_hook(live_view, "statement_search_change", %{"value" => "Fleury"})
      assert filtered =~ "Exame de Sangue Fleury"
      refute filtered =~ "Almoco Reuniao Externa"

      live_view
      |> element("button[phx-click='mark_reimbursable'][phx-value-id='#{candidate.id}']")
      |> render_click()

      assert CashLens.Transactions.get_transaction!(candidate.id).reimbursement_status ==
               "pending"

      live_view |> element("button[phx-click='close_statement_modal']") |> render_click()
      assert render(live_view) =~ "Exame de Sangue Fleury"
    end

    test "statement modal filters candidates by numeric amount", %{conn: conn} do
      acc = account_fixture()

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-84.20",
        description: "Uber Viagem Cliente",
        date: Date.utc_today()
      })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-350.00",
        description: "Consulta Clinica",
        date: Date.utc_today()
      })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")
      live_view |> element("button[phx-click='open_statement_modal']") |> render_click()

      by_decimal = render_hook(live_view, "statement_search_change", %{"value" => "84,20"})
      assert by_decimal =~ "Uber Viagem Cliente"
      refute by_decimal =~ "Consulta Clinica"

      by_integer = render_hook(live_view, "statement_search_change", %{"value" => "350"})
      assert by_integer =~ "Consulta Clinica"
      refute by_integer =~ "Uber Viagem Cliente"
    end

    test "statement modal hides transactions already marked as reimbursable", %{conn: conn} do
      acc = account_fixture()

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-99.00",
        description: "Ja marcada reembolsavel",
        reimbursement_status: "pending",
        date: Date.utc_today()
      })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-98.00",
        description: "Ainda nao marcada",
        date: Date.utc_today()
      })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")

      html = live_view |> element("button[phx-click='open_statement_modal']") |> render_click()

      candidates = html |> String.split("statement-candidates") |> Enum.at(1) || ""
      assert candidates =~ "Ainda nao marcada"
      refute candidates =~ "Ja marcada reembolsavel"
    end

    test "toggles the reimbursement badge between Pendente and Solicitado", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-210.00",
          description: "Consulta a solicitar"
        })

      {:ok, live_view, html} = live(conn, ~p"/reimbursements")
      assert html =~ "Pendente de Solicitação"

      requested_html =
        live_view
        |> element("button[phx-click='mark_requested'][phx-value-id='#{tx.id}']")
        |> render_click()

      assert requested_html =~ "Solicitado (Em Análise)"

      pending_html =
        live_view
        |> element("button[phx-click='mark_pending'][phx-value-id='#{tx.id}']")
        |> render_click()

      assert pending_html =~ "Pendente de Solicitação"
    end

    test "saves convenio and protocolo for a reimbursable expense", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-500.00",
          description: "Consulta Oftalmologista"
        })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")

      html =
        live_view
        |> form("form[phx-submit='save_reimbursement_details'][data-tx-id='#{tx.id}']", %{
          "carrier" => "Bradesco Saúde",
          "protocol" => "PROT-2026-9812"
        })
        |> render_submit()

      assert html =~ "PROT-2026-9812"
      assert html =~ "Bradesco Saúde"

      updated = CashLens.Transactions.get_transaction!(tx.id)
      assert updated.reimbursement_carrier == "Bradesco Saúde"
      assert updated.reimbursement_protocol == "PROT-2026-9812"
    end

    test "manual link modal reports a partial balance when the credit does not cover the expense",
         %{conn: conn} do
      acc = account_fixture()
      cat = category_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-200.00",
          description: "Despesa parcial",
          category_id: cat.id,
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "120.00",
          description: "Credito parcial",
          category_id: cat.id,
          date: ~D[2026-03-20]
        })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")

      live_view
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      html = render_click(live_view, "toggle_credit", %{"credit-id" => credit.id})

      refute html =~ "Match Perfeito"
      assert html =~ "Reembolso parcial"
      assert html =~ "80,00"
    end

    test "batch selection bar shows the selected total and opens the manual link modal",
         %{conn: conn} do
      acc = account_fixture()

      tx_a =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-100.00",
          description: "Lote A",
          date: ~D[2026-02-23]
        })

      tx_b =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-150.00",
          description: "Lote B",
          date: ~D[2026-02-24]
        })

      {:ok, live_view, _html} = live(conn, ~p"/reimbursements")

      live_view
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx_a.id}']")
      |> render_click()

      html =
        live_view
        |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx_b.id}']")
        |> render_click()

      assert html =~ "2 selecionados"
      assert html =~ "250,00"

      modal_html =
        live_view |> element("button[phx-click='open_batch_linker']") |> render_click()

      assert modal_html =~ "Vincular Crédito de Reembolso"
      assert modal_html =~ "Total a Cobrir"
    end
  end
end
