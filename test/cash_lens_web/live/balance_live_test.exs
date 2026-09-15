defmodule CashLensWeb.BalanceLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountingFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Accounting.BalanceAdjuster
  alias CashLens.Accounts
  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  defp open_modal(index_live, balance) do
    render_click(index_live, "open_adjust", %{
      "account_id" => balance.account_id,
      "year" => balance.year,
      "month" => balance.month
    })
  end

  defp create_balance(_) do
    today = Date.utc_today()
    balance = balance_fixture(year: today.year, month: today.month)
    %{balance: balance, today: today}
  end

  describe "Index" do
    setup [:create_balance]

    test "lists all balances", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/balances")
      assert html =~ "Histórico de Saldos"
    end

    test "renders balance with account that has no icon (shows initials)", %{conn: conn} do
      account = account_fixture(%{bank: "MyBank", icon: nil})
      today = Date.utc_today()
      balance_fixture(%{account_id: account.id, year: today.year, month: today.month})
      {:ok, _live, html} = live(conn, ~p"/balances")
      assert html =~ "My"
    end
  end

  describe "filter bar" do
    setup [:create_balance]

    test "renders year, month and account filters outside the table", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert has_element?(index_live, "#balance-filters select[name='year']")
      assert has_element?(index_live, "#balance-filters select[name='month']")
      assert has_element?(index_live, "#balance-filters select[name='account_id']")

      refute has_element?(index_live, "table thead select")
    end

    test "filters balances by year", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      html =
        index_live
        |> form("#filter-form", %{"year" => balance.year, "month" => "", "account_id" => ""})
        |> render_change()

      assert html =~ to_string(balance.year)
    end

    test "clears filters", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert has_element?(index_live, "#balance-filters button[phx-click='clear_filters']")

      render_click(index_live, "clear_filters", %{})
      assert render(index_live) =~ "Histórico de Saldos"
    end
  end

  describe "consolidated totals" do
    test "renders a tfoot row summing every visible column", %{conn: conn} do
      today = Date.utc_today()

      balance_fixture(%{
        year: today.year,
        month: today.month,
        initial_balance: "100.00",
        income: "50.00",
        expenses: "20.00",
        transfers_in: "10.00",
        transfers_out: "5.00",
        balance: "35.00",
        final_balance: "135.00"
      })

      balance_fixture(%{
        year: today.year,
        month: today.month,
        initial_balance: "200.00",
        income: "71.00",
        expenses: "32.00",
        transfers_in: "43.00",
        transfers_out: "7.00",
        balance: "75.00",
        final_balance: "275.00"
      })

      {:ok, index_live, _html} = live(conn, ~p"/balances")

      totals = index_live |> element("#balances-totals") |> render()

      assert totals =~ "TOTAL CONSOLIDADO"
      assert totals =~ "2 contas"
      # initial_balance: 100 + 200
      assert totals =~ "R$ 300,00"
      # income: 50 + 71
      assert totals =~ "R$ 121,00"
      # expenses: 20 + 32
      assert totals =~ "R$ 52,00"
      # transfers_in: 10 + 43
      assert totals =~ "R$ 53,00"
      # transfers_out: 5 + 7
      assert totals =~ "R$ 12,00"
      # final_balance: 135 + 275
      assert totals =~ "R$ 410,00"
    end

    test "renders zeroed totals when there are no balances", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      totals = index_live |> element("#balances-totals") |> render()
      assert totals =~ "R$ 0,00"
    end
  end

  describe "row navigation" do
    setup [:create_balance]

    test "row click navigates to the account statement for that month", %{
      conn: conn,
      balance: balance,
      today: today
    } do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert has_element?(index_live, "#balances-#{balance.id}[phx-click='open_statement']")

      render_click(index_live, "open_statement", %{
        "account_id" => balance.account_id,
        "year" => balance.year,
        "month" => balance.month
      })

      assert_redirect(
        index_live,
        "/transactions?account_id=#{balance.account_id}&year=#{today.year}&month=#{today.month}"
      )
    end
  end

  describe "legacy elements removed" do
    setup [:create_balance]

    test "no read-only column, no 'Ver Extrato' column and no 'Recalcular Tudo' button", %{
      conn: conn
    } do
      {:ok, index_live, html} = live(conn, ~p"/balances")

      refute html =~ "Somente leitura"
      refute html =~ "Ver Extrato"
      refute html =~ "Recalcular Tudo"
      refute has_element?(index_live, "button[phx-click='recalculate_all']")
    end
  end

  describe "adjust balance modal" do
    setup [:create_balance]

    test "pencil button opens the modal with both adjustment options", %{
      conn: conn,
      balance: balance
    } do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert has_element?(
               index_live,
               "#balances-#{balance.id} button[phx-click='open_adjust']"
             )

      html = open_modal(index_live, balance)

      assert html =~ "Ajustar Saldo Final"
      assert html =~ "Rendimento do Mês"
      assert html =~ "Correção de Saldo Inicial Histórico"
      assert html =~ "R$ 120,50"
    end

    test "modal can be closed", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      open_modal(index_live, balance)
      assert has_element?(index_live, "#adjust-balance-modal")

      render_click(index_live, "close_adjust", %{})
      refute has_element?(index_live, "#adjust-balance-modal")
    end

    test "typing the real balance shows the difference in real time", %{
      conn: conn,
      balance: balance
    } do
      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "150.50", "adjust_type" => "rendimento"}
        })
        |> render_change()

      assert html =~ "R$ 30,00"
    end

    test "rendimento creates an income transaction on the last day of the month", %{
      conn: conn,
      balance: balance,
      today: today
    } do
      category = category_fixture(%{name: "Rendimento"})

      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "150.50", "adjust_type" => "rendimento"}
        })
        |> render_submit()

      assert html =~ "Rendimento"

      transaction =
        Repo.get_by!(Transaction, account_id: balance.account_id, description: "Rendimento")

      assert Decimal.equal?(transaction.amount, Decimal.new("30.00"))
      assert transaction.category_id == category.id
      assert transaction.date == Date.end_of_month(Date.new!(today.year, today.month, 1))
    end

    test "rendimento fails gracefully when the category does not exist", %{
      conn: conn,
      balance: balance
    } do
      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "150.50", "adjust_type" => "rendimento"}
        })
        |> render_submit()

      assert html =~ "Categoria Rendimento não encontrada"
    end

    test "correcao shifts the account opening balance and rebuilds the chain", %{
      conn: conn,
      balance: balance
    } do
      account = Accounts.get_account!(balance.account_id)

      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "150.50", "adjust_type" => "correcao"}
        })
        |> render_submit()

      assert html =~ "Saldo inicial"

      updated = Accounts.get_account!(balance.account_id)
      assert Decimal.equal?(updated.balance, Decimal.add(account.balance, Decimal.new("30.00")))
    end

    test "no difference reports nothing to adjust", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "120.50", "adjust_type" => "rendimento"}
        })
        |> render_submit()

      assert html =~ "Nenhuma diferença"
    end

    test "shows a negative and a zeroed difference", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      negative =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "100.00", "adjust_type" => "correcao"}
        })
        |> render_change()

      assert negative =~ "R$ -20,50"

      zeroed =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "120.50", "adjust_type" => "rendimento"}
        })
        |> render_change()

      assert zeroed =~ "R$ 0,00"
    end

    test "opening the modal for a period without balance reports an error", %{
      conn: conn,
      balance: balance
    } do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      html =
        render_click(index_live, "open_adjust", %{
          "account_id" => balance.account_id,
          "year" => "1999",
          "month" => "1"
        })

      assert html =~ "Saldo não encontrado"
      refute has_element?(index_live, "#adjust-balance-modal")
    end

    test "reports an error when the balance vanishes while the modal is open", %{
      conn: conn,
      balance: balance
    } do
      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      Repo.delete!(balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "150.50", "adjust_type" => "rendimento"}
        })
        |> render_submit()

      assert html =~ "Saldo não encontrado"
    end

    test "reports a duplicate rendimento instead of booking it twice", %{
      conn: conn,
      balance: balance,
      today: today
    } do
      category = category_fixture(%{name: "Rendimento"})
      last_day = Date.end_of_month(Date.new!(today.year, today.month, 1))

      {:ok, %Transaction{}} =
        Transactions.create_transaction(%{
          account_id: balance.account_id,
          date: last_day,
          description: "Rendimento",
          amount: Decimal.new("30.00"),
          category_id: category.id
        })

      current =
        BalanceAdjuster.current_final_balance(
          balance.account_id,
          today.year,
          today.month
        )

      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{
            "real_balance" => Decimal.to_string(Decimal.add(current, Decimal.new("30.00"))),
            "adjust_type" => "rendimento"
          }
        })
        |> render_submit()

      assert html =~ "Já existe uma transação idêntica"
    end

    test "a blank real balance is rejected", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "", "adjust_type" => "rendimento"}
        })
        |> render_submit()

      assert html =~ "Informe o saldo real"
    end
  end
end
