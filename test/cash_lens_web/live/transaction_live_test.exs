defmodule CashLensWeb.TransactionLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  @create_attrs %{
    date: Date.utc_today(),
    description: "some description",
    amount: "120.5"
  }
  @update_attrs %{
    date: Date.utc_today(),
    description: "some updated description",
    amount: "456.7"
  }
  @invalid_attrs %{date: nil, description: nil, amount: nil}

  defp create_transaction(_) do
    transaction = transaction_fixture()
    %{transaction: transaction}
  end

  describe "Index" do
    setup [:create_transaction]

    test "lists all transactions", %{conn: conn, transaction: transaction} do
      {:ok, _index_live, html} = live(conn, ~p"/transactions")

      assert html =~ "Transações"
      assert html =~ transaction.description
    end

    test "saves new transaction", %{conn: conn} do
      account = account_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live
      |> element("main a[href='/transactions/new']")
      |> render_click()

      assert_patch(index_live, ~p"/transactions/new")
      assert has_element?(index_live, "#transaction-form-modal")

      assert index_live
             |> form("#transaction-form", transaction: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      index_live
      |> form("#transaction-form",
        transaction: Map.put(@create_attrs, :account_id, account.id)
      )
      |> render_submit()

      assert_patch(index_live, ~p"/transactions")
      assert render(index_live) =~ "some description"
      refute has_element?(index_live, "#transaction-form-modal")
    end

    test "updates transaction in listing", %{conn: conn, transaction: transaction} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live
      |> element("#transactions-#{transaction.id} a[href$='/edit']")
      |> render_click()

      assert_patch(index_live, ~p"/transactions/#{transaction}/edit")
      assert has_element?(index_live, "#transaction-form-modal")

      assert index_live
             |> form("#transaction-form", transaction: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      index_live
      |> form("#transaction-form", transaction: @update_attrs)
      |> render_submit()

      assert_patch(index_live, ~p"/transactions")
      assert render(index_live) =~ "some updated description"
      refute has_element?(index_live, "#transaction-form-modal")
    end

    test "deletes transaction in listing only after the confirmation modal", %{
      conn: conn,
      transaction: transaction
    } do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      assert index_live
             |> element("#transactions-#{transaction.id} button[phx-click='confirm_delete']")
             |> render_click()

      # Still on screen: opening the modal must not delete anything.
      assert has_element?(index_live, "#transactions-#{transaction.id}")

      index_live |> element("#confirm-delete-transaction-btn") |> render_click()
      refute has_element?(index_live, "#transactions-#{transaction.id}")
    end

    test "renders sync_pluggy button and handles click", %{conn: conn} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{"apiKey" => "test-api-key", "results" => []})
      end)

      {:ok, index_live, html} = live(conn, ~p"/transactions")
      Req.Test.allow(CashLens.Pluggy.Client, self(), index_live.pid)
      assert html =~ "Sincronizar Pluggy"

      assert render_click(index_live, "sync_pluggy") =~ "Pluggy"
    end
  end

  describe "Show" do
    setup [:create_transaction]

    test "displays transaction in an overlaid modal", %{conn: conn, transaction: transaction} do
      {:ok, live, html} = live(conn, ~p"/transactions/#{transaction}")

      assert has_element?(live, "#transaction-show-modal")
      assert html =~ "Detalhes da Transação"
      assert html =~ transaction.description
    end

    test "edit link inside the show modal patches to the edit modal", %{
      conn: conn,
      transaction: transaction
    } do
      {:ok, live, _html} = live(conn, ~p"/transactions/#{transaction}")

      live
      |> element("#transaction-show-modal a[href$='/edit']")
      |> render_click()

      assert_patch(live, ~p"/transactions/#{transaction}/edit")
      assert has_element?(live, "#transaction-form-modal")
    end
  end

  describe "Modals, Linking and Transfers" do
    setup [:create_transaction]

    test "toggles sorting and views", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button[phx-click='toggle_sort']") |> render_click()
      live |> element("button[phx-value-type='credit']") |> render_click()
      assert render(live) =~ "Transações"
    end

    test "handles reimbursement linking", %{conn: conn, transaction: _tx} do
      account = account_fixture()

      expense =
        transaction_fixture(amount: "-100.00", account_id: account.id, description: "Lunch")

      reimb_cat = category_fixture(%{name: "Reimbursable", slug: "reimbursable"})

      {:ok, expense} =
        CashLens.Transactions.update_transaction(expense, %{
          category_id: reimb_cat.id,
          reimbursement_status: "pending"
        })

      credit =
        transaction_fixture(
          amount: "100.00",
          account_id: account.id,
          date: expense.date,
          description: "Refund"
        )

      {:ok, live, _html} = live(conn, ~p"/transactions")

      live
      |> element("button[phx-click='open_reimbursement_link'][phx-value-id='#{credit.id}']")
      |> render_click()

      assert render(live) =~ "Vincular Reembolso"

      live
      |> element("button[phx-click='link_reimbursement'][phx-value-expense-id='#{expense.id}']")
      |> render_click()

      assert render(live) =~ "Reembolso vinculado"
    end

    test "handles transfer linking and creation", %{conn: conn, transaction: _tx} do
      account = account_fixture()
      transfer_cat = category_fixture(%{name: "Transfer", slug: "transfer"})

      tx =
        transaction_fixture(
          amount: "-50.00",
          account_id: account.id,
          category_id: transfer_cat.id
        )

      target_account = account_fixture(name: "Target")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      live
      |> element("button[phx-click='open_transfer_link'][phx-value-id='#{tx.id}']")
      |> render_click()

      assert render(live) =~ "Vincular Transferência"
      live |> element("button[phx-click='open_quick_transfer']") |> render_click()

      assert render(live) =~ "Criar Par de Transferência"

      live
      |> form("#quick-transfer-form", %{
        "account_id" => target_account.id,
        "description" => "Transfer",
        "date" => Date.to_string(tx.date),
        "amount" => "50.0"
      })
      |> render_submit()

      assert render(live) =~ "Par de transferência criado"
    end

    test "deletes all transactions", %{conn: conn} do
      transaction_fixture()
      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button[phx-click='confirm_delete_all']") |> render_click()
      render_click(live, "delete_all")
      # Check that the stream is empty (no tr elements with id starting with transactions-)
      refute render(live) =~ "id=\"transactions-"
    end

    test "auto-categorizes all transactions", %{conn: conn} do
      category_fixture(%{name: "Streaming", keywords: "NETFLIX"})
      transaction_fixture(%{description: "NETFLIX", category_id: nil})

      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button", "Auto-Categorizar") |> render_click()

      assert render(live) =~ "Regras aplicadas!"
    end

    test "filters by search and clear filters", %{conn: conn} do
      transaction_fixture(%{description: "SearchTarget"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      live |> form("#transaction-filters", %{"search" => "SearchTarget"}) |> render_change()
      assert render(live) =~ "SearchTarget"

      live |> element("button[phx-click='clear_filters']") |> render_click()
      assert render(live) =~ "Transações"
    end

    test "toggles pending transactions", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      # Two controls share this event (header toggle + health bar counter), so
      # the header one is addressed by its id.
      live |> element("#toggle-pending-btn") |> render_click()
      assert render(live) =~ "Pendentes"
    end

    test "handles pagination via infinite scroll", %{conn: conn} do
      for i <- 1..60, do: transaction_fixture(%{description: "Pagination #{i}"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      # Trigger infinite scroll event
      render_hook(live, "load-more", %{"page" => "1"})
      assert render(live) =~ "Pagination"
    end
  end

  describe "CL-9 statement redesign" do
    setup do
      %{account: account_fixture()}
    end

    defp row_ids(html) do
      Regex.scan(~r/id="transactions-([0-9a-f-]+)"/, html) |> Enum.map(&List.last/1)
    end

    test "lists transactions from newest to oldest by default", %{conn: conn, account: account} do
      for {date, description} <- [
            {~D[2026-01-05], "Oldest movement"},
            {~D[2026-03-05], "Newest movement"},
            {~D[2026-02-05], "Middle movement"}
          ] do
        transaction_fixture(%{account_id: account.id, date: date, description: description})
      end

      {:ok, _live, html} = live(conn, ~p"/transactions")

      positions =
        Enum.map(
          ["Newest movement", "Middle movement", "Oldest movement"],
          &:binary.match(html, &1)
        )

      assert positions == Enum.sort(positions)
    end

    test "does not lock the period to the current month by default", %{
      conn: conn,
      account: account
    } do
      old = Date.add(Date.utc_today(), -120)

      transaction_fixture(%{
        account_id: account.id,
        date: old,
        description: "Lancamento antigo"
      })

      {:ok, live, html} = live(conn, ~p"/transactions")

      assert html =~ "Lancamento antigo"
      assert has_element?(live, "#filter-period option[value=''][selected]")
      assert html =~ "Todos os Períodos"
    end

    test "reflects a month/year deep link in the period select", %{conn: conn, account: account} do
      transaction_fixture(%{
        account_id: account.id,
        date: ~D[2020-03-15],
        description: "Antiga de marco"
      })

      {:ok, live, html} = live(conn, ~p"/transactions?month=3&year=2020")

      assert html =~ "Antiga de marco"
      assert has_element?(live, "#filter-period option[value='2020-03'][selected]")
    end

    test "renders the statement health bar with clickable counters", %{
      conn: conn,
      account: account
    } do
      transaction_fixture(%{account_id: account.id, description: "Sem categoria"})

      {:ok, live, _html} = live(conn, ~p"/transactions")

      assert has_element?(live, "#statement-health-bar")
      assert has_element?(live, "#statement-health-bar button[phx-click='toggle_pending']")
      assert has_element?(live, "#statement-health-bar a[href='/reimbursements']")
      assert has_element?(live, "#statement-health-bar a[href='/transfers']")
      refute has_element?(live, "#filter-summary-card")
    end

    test "health bar's Sem Categoria counter filters the statement in place", %{
      conn: conn,
      account: account
    } do
      category = category_fixture(%{name: "Mercado", slug: "mercado"})

      transaction_fixture(%{
        account_id: account.id,
        description: "Ja categorizada",
        category_id: category.id
      })

      transaction_fixture(%{account_id: account.id, description: "Sem categoria ainda"})

      {:ok, live, _html} = live(conn, ~p"/transactions")

      html =
        live
        |> element("#statement-health-bar button[phx-click='toggle_pending']")
        |> render_click()

      assert html =~ "Sem categoria ainda"
      refute html =~ "Ja categorizada"
    end

    test "period select narrows the statement to the chosen month", %{
      conn: conn,
      account: account
    } do
      today = Date.utc_today()
      current_period = "#{today.year}-#{String.pad_leading("#{today.month}", 2, "0")}"

      transaction_fixture(%{
        account_id: account.id,
        date: today,
        description: "Deste mes"
      })

      transaction_fixture(%{
        account_id: account.id,
        date: Date.add(today, -200),
        description: "De outro mes"
      })

      {:ok, live, _html} = live(conn, ~p"/transactions")

      html =
        live
        |> form("#transaction-filters", %{"period" => current_period})
        |> render_change()

      assert html =~ "Deste mes"
      refute html =~ "De outro mes"

      # Back to the continuous flow.
      html =
        live
        |> form("#transaction-filters", %{"period" => ""})
        |> render_change()

      assert html =~ "Deste mes"
      assert html =~ "De outro mes"
      assert has_element?(live, "#statement-health-bar")
    end

    test "swaps the health bar for the financial summary card when a filter is applied", %{
      conn: conn,
      account: account
    } do
      transaction_fixture(%{account_id: account.id, description: "Mercado", amount: "-30.00"})
      transaction_fixture(%{account_id: account.id, description: "Mercado", amount: "90.00"})

      {:ok, live, _html} = live(conn, ~p"/transactions")

      html =
        live
        |> form("#transaction-filters", %{"search" => "Mercado"})
        |> render_change()

      assert has_element?(live, "#filter-summary-card")
      refute has_element?(live, "#statement-health-bar")
      assert html =~ "Entradas"
      assert html =~ "Saídas"
      assert html =~ "Balanço Líquido"
    end

    test "infinite scroll appends the next page without duplicating or skipping rows", %{
      conn: conn,
      account: account
    } do
      for i <- 1..60 do
        transaction_fixture(%{
          account_id: account.id,
          date: Date.add(~D[2026-01-01], i),
          description: "Scroll #{i}"
        })
      end

      {:ok, live, html} = live(conn, ~p"/transactions")

      first_page = row_ids(html)
      assert length(first_page) == 50

      full = row_ids(render_hook(live, "load-more", %{}))

      assert length(full) == 60
      assert length(Enum.uniq(full)) == 60
      # The first page must keep its position; page 2 is appended after it.
      assert Enum.take(full, 50) == first_page

      dates =
        Enum.map(full, fn id -> CashLens.Transactions.get_transaction!(id).date end)

      assert dates == Enum.sort(dates, {:desc, Date})
    end

    test "paginates deterministically when every row shares the same date", %{
      conn: conn,
      account: account
    } do
      # Worst case for an offset-based page boundary: date, time and inserted_at
      # all collide, so only the description/id tiebreakers keep the ordering
      # stable. Without them a row could repeat or vanish between the pages.
      for i <- 1..60 do
        transaction_fixture(%{
          account_id: account.id,
          date: ~D[2026-04-10],
          description: "Mesma data #{i}",
          amount: "-10.00"
        })
      end

      {:ok, live, html} = live(conn, ~p"/transactions")
      full = row_ids(render_hook(live, "load-more", %{}))

      assert length(row_ids(html)) == 50
      assert length(full) == 60
      assert length(Enum.uniq(full)) == 60

      assert MapSet.new(full) ==
               MapSet.new(Enum.map(CashLens.Transactions.list_all_transactions(), & &1.id))
    end

    test "applying a filter resets the stream instead of appending to it", %{
      conn: conn,
      account: account
    } do
      for i <- 1..60 do
        transaction_fixture(%{
          account_id: account.id,
          date: Date.add(~D[2026-01-01], i),
          description: "Scroll #{i}"
        })
      end

      transaction_fixture(%{account_id: account.id, description: "AlvoUnico"})

      {:ok, live, _html} = live(conn, ~p"/transactions")
      render_hook(live, "load-more", %{})

      html =
        live
        |> form("#transaction-filters", %{"search" => "AlvoUnico"})
        |> render_change()

      assert length(row_ids(html)) == 1
      assert html =~ "AlvoUnico"
      refute html =~ "Scroll 1<"
    end

    test "approves a suggested category with a single click", %{conn: conn, account: account} do
      category = category_fixture(%{name: "Streaming", slug: "streaming"})

      transaction_fixture(%{
        account_id: account.id,
        description: "NETFLIX.COM",
        category_id: category.id,
        date: ~D[2026-01-01]
      })

      pending =
        transaction_fixture(%{
          account_id: account.id,
          description: "NETFLIX.COM",
          date: ~D[2026-02-01]
        })

      {:ok, live, html} = live(conn, ~p"/transactions")

      assert html =~ "Sugestão: Streaming"

      live
      |> element("#transactions-#{pending.id} button[data-role='category-suggestion']")
      |> render_click()

      assert CashLens.Transactions.get_transaction!(pending.id).category_id == category.id
    end

    test "shows reimbursement badges linking the expense and its deposit credit", %{
      conn: conn,
      account: account
    } do
      expense =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-100.00",
          date: ~D[2026-02-01],
          description: "Consulta medica"
        })

      {:ok, expense} =
        CashLens.Transactions.update_transaction(expense, %{reimbursement_status: "pending"})

      credit =
        transaction_fixture(%{
          account_id: account.id,
          amount: "100.00",
          date: ~D[2026-02-10],
          description: "Credito Unimed"
        })

      {:ok, {_expense, _credit}} =
        CashLens.Transactions.link_reimbursement_pair(expense.id, credit.id)

      {:ok, live, _html} = live(conn, ~p"/transactions")

      assert has_element?(
               live,
               "#transactions-#{expense.id} [data-role='reimbursement-link']"
             )

      assert has_element?(
               live,
               "#transactions-#{credit.id} [data-role='reimbursement-link']"
             )

      # From the expense row, the badge reveals the credit side of the pair.
      html =
        live
        |> element("#transactions-#{expense.id} [data-role='reimbursement-link']")
        |> render_click()

      assert html =~ "Credito Unimed"
      assert html =~ "Consulta medica"

      # And the link works in the other direction too.
      html =
        live
        |> element("#transactions-#{credit.id} [data-role='reimbursement-link']")
        |> render_click()

      assert html =~ "Consulta medica"
    end
  end

  describe "CL-10 unified transaction modals" do
    setup do
      %{account: account_fixture()}
    end

    test "opening and closing the new modal never re-fetches the statement stream", %{
      conn: conn,
      account: account
    } do
      transaction_fixture(%{account_id: account.id, description: "Ja no extrato"})

      {:ok, live, html} = live(conn, ~p"/transactions")
      assert html =~ "Ja no extrato"

      # Inserted behind the LiveView's back: it may only show up if the stream
      # is re-fetched from page 1, which patching a modal must never do.
      transaction_fixture(%{account_id: account.id, description: "InseridaAposMount"})

      html =
        live
        |> element("main a[href='/transactions/new']")
        |> render_click()

      assert has_element?(live, "#transaction-form-modal")
      assert html =~ "Ja no extrato"
      refute html =~ "InseridaAposMount"

      html = live |> element("#transaction-form-modal-close") |> render_click()

      assert_patch(live, ~p"/transactions")
      refute has_element?(live, "#transaction-form-modal")
      assert html =~ "Ja no extrato"
      refute html =~ "InseridaAposMount"
    end

    test "deep linking straight to a modal still loads the statement behind it", %{
      conn: conn,
      account: account
    } do
      transaction_fixture(%{account_id: account.id, description: "Fundo do extrato"})

      {:ok, live, html} = live(conn, ~p"/transactions/new")

      assert has_element?(live, "#transaction-form-modal")
      assert html =~ "Fundo do extrato"
    end

    test "a filter arriving in the URL still rebuilds the stream", %{conn: conn, account: account} do
      transaction_fixture(%{account_id: account.id, description: "AlvoDeBusca"})
      transaction_fixture(%{account_id: account.id, description: "Outro lancamento"})

      {:ok, live, _html} = live(conn, ~p"/transactions")

      html = render_patch(live, ~p"/transactions?search=AlvoDeBusca")

      assert html =~ "AlvoDeBusca"
      refute html =~ "Outro lancamento"
    end

    test "amount field gives live expense/income feedback from the typed sign", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      html =
        live
        |> form("#transaction-form",
          transaction: %{amount: "-80,00", description: "Mercado", account_id: account.id}
        )
        |> render_change()

      assert html =~ "Despesa"
      assert has_element?(live, "#transaction-amount-hint[data-kind='expense']")

      html =
        live
        |> form("#transaction-form",
          transaction: %{amount: "2500,00", description: "Salario", account_id: account.id}
        )
        |> render_change()

      assert html =~ "Receita"
      assert has_element?(live, "#transaction-amount-hint[data-kind='income']")
    end

    test "form has no income/expense toggle", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      refute has_element?(live, "#transaction-form input[type='radio']")
      refute has_element?(live, "#transaction-form [name='transaction[kind]']")
      refute has_element?(live, "#transaction-form [name='transaction[transaction_type]']")
    end

    test "persists the typed sign straight into the amount column", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      live
      |> form("#transaction-form",
        transaction: %{
          amount: "-1.234,56",
          description: "Despesa assinada",
          date: Date.to_iso8601(~D[2026-05-10]),
          account_id: account.id
        }
      )
      |> render_submit()

      assert_patch(live, ~p"/transactions")

      [created] =
        CashLens.Transactions.list_all_transactions()
        |> Enum.filter(&(&1.description == "Despesa assinada"))

      assert Decimal.equal?(created.amount, Decimal.new("-1234.56"))
    end

    test "rejects a malformed amount without crashing", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      html =
        live
        |> form("#transaction-form",
          transaction: %{amount: "abc", description: "Invalida", account_id: account.id}
        )
        |> render_submit()

      assert html =~ "Valor inválido"
      assert has_element?(live, "#transaction-form-modal")
      assert CashLens.Transactions.list_all_transactions() == []
    end

    test "editing and saving an existing expense keeps its negative sign", %{
      conn: conn,
      account: account
    } do
      transaction =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-800.00",
          description: "Consulta"
        })

      {:ok, live, html} = live(conn, ~p"/transactions/#{transaction}/edit")

      assert html =~ "-800,00"

      live
      |> form("#transaction-form", transaction: %{description: "Consulta revisada"})
      |> render_submit()

      assert_patch(live, ~p"/transactions")

      updated = CashLens.Transactions.get_transaction!(transaction.id)
      assert updated.description == "Consulta revisada"
      assert Decimal.equal?(updated.amount, Decimal.new("-800.00"))
    end

    test "delete confirmation modal shows description, date, account and amount", %{
      conn: conn,
      account: account
    } do
      transaction =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-800.00",
          date: ~D[2026-09-10],
          description: "Consulta Dr. Roberto"
        })

      {:ok, live, _html} = live(conn, ~p"/transactions")

      html =
        live
        |> element("#transactions-#{transaction.id} button[phx-click='confirm_delete']")
        |> render_click()

      assert html =~ "Consulta Dr. Roberto"
      assert html =~ "10/09/2026"
      assert html =~ CashLensWeb.Formatters.account_label(account)
      assert html =~ "R$ -800,00"
      assert has_element?(live, "#confirm-delete-transaction-btn")

      # Cancelling leaves the transaction untouched.
      live |> element("#confirm-modal button[phx-click='close_modal']") |> render_click()
      assert CashLens.Transactions.get_transaction!(transaction.id)
    end

    test "edit modal shows the traceability block for a linked transaction", %{
      conn: conn,
      account: account
    } do
      expense =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-100.00",
          date: ~D[2026-02-01],
          description: "Consulta medica"
        })

      {:ok, expense} =
        CashLens.Transactions.update_transaction(expense, %{reimbursement_status: "pending"})

      credit =
        transaction_fixture(%{
          account_id: account.id,
          amount: "100.00",
          date: ~D[2026-02-10],
          description: "Credito Unimed"
        })

      {:ok, {expense, _credit}} =
        CashLens.Transactions.link_reimbursement_pair(expense.id, credit.id)

      {:ok, live, html} = live(conn, ~p"/transactions/#{expense}/edit")

      assert has_element?(live, "#transaction-links")
      assert html =~ "Conciliações &amp; Rastreabilidade"
      assert html =~ "Credito Unimed"
    end

    test "traceability block names a transfer pair and an installment group", %{
      conn: conn,
      account: account
    } do
      other_account = account_fixture(%{name: "Destino"})
      transfer_key = Ecto.UUID.generate()

      group =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "GELADEIRA",
          installments: 12,
          start_date: ~D[2026-01-10],
          total_amount: Decimal.new("1200.00")
        })
        |> elem(1)

      origin =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-500.00",
          description: "Saida para destino"
        })

      transaction_fixture(%{
        account_id: other_account.id,
        amount: "500.00",
        description: "Entrada do destino"
      })
      |> CashLens.Transactions.update_transaction(%{transfer_key: transfer_key})

      {:ok, origin} =
        CashLens.Transactions.update_transaction(origin, %{
          transfer_key: transfer_key,
          installment_group_id: group.id,
          installment_number: 1
        })

      {:ok, live, html} = live(conn, ~p"/transactions/#{origin}/edit")

      assert has_element?(live, "#transaction-links")
      assert html =~ "Entrada do destino"
      assert html =~ "GELADEIRA"
    end

    test "traceability block names the statement this transaction settles", %{
      conn: conn,
      account: account
    } do
      card = account_fixture(%{name: "Cartao", is_credit_card: true})

      {:ok, statement} =
        CashLens.CreditCards.create_statement(%{
          account_id: card.id,
          competencia: ~D[2026-06-01],
          due_date: ~D[2026-06-15],
          total_a_pagar: Decimal.new("100.00")
        })

      payment =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-100.00",
          date: ~D[2026-06-15],
          description: "Pagamento fatura"
        })

      {:ok, _result} = CashLens.CreditCards.link_payment(statement, payment.id)

      {:ok, live, html} = live(conn, ~p"/transactions/#{payment}/edit")

      assert has_element?(live, "#transaction-links")
      assert html =~ "Fatura"
      assert html =~ "01/06/2026"
    end

    test "a duplicate manual entry is reported instead of silently created", %{
      conn: conn,
      account: account
    } do
      attrs = %{
        amount: "-42,00",
        description: "Lancamento repetido",
        date: Date.to_iso8601(~D[2026-05-10]),
        account_id: account.id
      }

      {:ok, live, _html} = live(conn, ~p"/transactions/new")
      live |> form("#transaction-form", transaction: attrs) |> render_submit()
      assert_patch(live, ~p"/transactions")

      {:ok, live, _html} = live(conn, ~p"/transactions/new")
      live |> form("#transaction-form", transaction: attrs) |> render_submit()
      assert_patch(live, ~p"/transactions")

      assert render(live) =~ "já existe"

      assert CashLens.Transactions.list_all_transactions()
             |> Enum.count(&(&1.description == "Lancamento repetido")) == 1
    end

    test "edit modal omits the traceability block when there is nothing linked", %{
      conn: conn,
      account: account
    } do
      transaction = transaction_fixture(%{account_id: account.id, description: "Solta"})

      {:ok, live, _html} = live(conn, ~p"/transactions/#{transaction}/edit")

      refute has_element?(live, "#transaction-links")
    end
  end
end
