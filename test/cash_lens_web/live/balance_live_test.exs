defmodule CashLensWeb.BalanceLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
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

  describe "grouped blocks and per-group totals" do
    @column_headers [
      "Conta",
      "Período",
      "Saldo Inicial",
      "Receitas",
      "Despesas",
      "Transf. Entrada",
      "Transf. Saída",
      "Saldo Final"
    ]

    defp cash_account(attrs \\ %{}) do
      account_fixture(Map.merge(%{is_credit_card: false}, attrs))
    end

    defp card_account(attrs \\ %{}) do
      account_fixture(Map.merge(%{is_credit_card: true}, attrs))
    end

    defp current_balance(account, attrs) do
      today = Date.utc_today()

      attrs
      |> Map.merge(%{account_id: account.id, year: today.year, month: today.month})
      |> balance_fixture()
    end

    test "renders a Contas block and a Cartões de Crédito block with independent totals", %{
      conn: conn
    } do
      first_cash =
        current_balance(cash_account(), %{
          initial_balance: "100.00",
          income: "50.00",
          expenses: "20.00",
          transfers_in: "10.00",
          transfers_out: "5.00",
          balance: "35.00",
          final_balance: "135.00"
        })

      second_cash =
        current_balance(cash_account(), %{
          initial_balance: "200.00",
          income: "71.00",
          expenses: "32.00",
          transfers_in: "43.00",
          transfers_out: "7.00",
          balance: "75.00",
          final_balance: "275.00"
        })

      card =
        current_balance(card_account(), %{
          initial_balance: "-300.00",
          income: "45.50",
          expenses: "45.50",
          transfers_in: "1.00",
          transfers_out: "2.00",
          balance: "0.00",
          final_balance: "-300.00"
        })

      {:ok, index_live, html} = live(conn, ~p"/balances")

      assert has_element?(index_live, "#balances-cash")
      assert has_element?(index_live, "#balances-cards")
      assert index_live |> element("#balances-cash-title") |> render() =~ "Contas"
      assert index_live |> element("#balances-cards-title") |> render() =~ "Cartões de Crédito"

      # The cash block comes first in the HTML source.
      assert :binary.match(html, "balances-cash") |> elem(0) <
               :binary.match(html, "balances-cards") |> elem(0)

      # Every row sits in exactly one block.
      for balance <- [first_cash, second_cash] do
        assert has_element?(index_live, "#balances-cash #balances-#{balance.id}")
        refute has_element?(index_live, "#balances-cards #balances-#{balance.id}")
      end

      assert has_element?(index_live, "#balances-cards #balances-#{card.id}")
      refute has_element?(index_live, "#balances-cash #balances-#{card.id}")

      # Both blocks carry the same column headers.
      for block <- ["#balances-cash", "#balances-cards"], header <- @column_headers do
        assert index_live |> element("#{block} thead") |> render() =~ header
      end

      cash_totals = index_live |> element("#balances-totals-cash") |> render()

      assert cash_totals =~ "TOTAL EM CONTAS (2 contas)"
      # initial_balance: 100 + 200
      assert cash_totals =~ "R$ 300,00"
      # income: 50 + 71
      assert cash_totals =~ "R$ 121,00"
      # expenses: 20 + 32
      assert cash_totals =~ "R$ 52,00"
      # transfers_in: 10 + 43
      assert cash_totals =~ "R$ 53,00"
      # transfers_out: 5 + 7
      assert cash_totals =~ "R$ 12,00"
      # final_balance: 135 + 275
      assert cash_totals =~ "R$ 410,00"
      # The card row never leaks into the cash totals.
      refute cash_totals =~ "45,50"

      cards_totals = index_live |> element("#balances-totals-cards") |> render()

      assert cards_totals =~ "TOTAL EM CARTÕES (1 cartões)"
      assert cards_totals =~ "R$ -300,00"
      assert cards_totals =~ "R$ 45,50"
      assert cards_totals =~ "R$ 1,00"
      assert cards_totals =~ "R$ 2,00"
      # The cash rows never leak into the card totals.
      refute cards_totals =~ "R$ 410,00"

      # There is no consolidated total any more: only the two per-group rows.
      refute has_element?(index_live, "#balances-totals")
      refute html =~ "CONSOLIDADO"
    end

    test "omits the Contas block when every visible row is a credit card", %{conn: conn} do
      today = Date.utc_today()
      card = card_account()
      current_balance(cash_account(), %{})
      current_balance(card, %{})

      {:ok, index_live, _html} = live(conn, ~p"/balances")

      html =
        index_live
        |> form("#filter-form", %{
          "year" => to_string(today.year),
          "month" => to_string(today.month),
          "account_id" => card.id
        })
        |> render_change()

      assert has_element?(index_live, "#balances-cards")
      assert has_element?(index_live, "#balances-totals-cards")
      refute has_element?(index_live, "#balances-cash")
      refute has_element?(index_live, "#balances-cash-title")
      refute has_element?(index_live, "#balances-totals-cash")
      refute html =~ "TOTAL EM CONTAS"
      refute has_element?(index_live, "#balances-empty")
    end

    test "omits the Cartões de Crédito block when no visible row is a credit card", %{conn: conn} do
      today = Date.utc_today()
      cash = cash_account()
      current_balance(cash, %{})
      current_balance(card_account(), %{})

      {:ok, index_live, _html} = live(conn, ~p"/balances")

      html =
        index_live
        |> form("#filter-form", %{
          "year" => to_string(today.year),
          "month" => to_string(today.month),
          "account_id" => cash.id
        })
        |> render_change()

      assert has_element?(index_live, "#balances-cash")
      assert has_element?(index_live, "#balances-totals-cash")
      refute has_element?(index_live, "#balances-cards")
      refute has_element?(index_live, "#balances-cards-title")
      refute has_element?(index_live, "#balances-totals-cards")
      refute html =~ "TOTAL EM CARTÕES"
      refute has_element?(index_live, "#balances-empty")
    end

    test "keeps the card total negative, matching the rows above it", %{conn: conn} do
      current_balance(card_account(), %{
        initial_balance: "-2000.00",
        income: "0.00",
        expenses: "100.00",
        balance: "-100.00",
        final_balance: "-2100.00"
      })

      current_balance(card_account(), %{
        initial_balance: "-3000.00",
        income: "0.00",
        expenses: "137.42",
        balance: "-137.42",
        final_balance: "-3137.42"
      })

      {:ok, index_live, _html} = live(conn, ~p"/balances")

      cards_totals = index_live |> element("#balances-totals-cards") |> render()

      assert cards_totals =~ "TOTAL EM CARTÕES (2 cartões)"
      # final_balance: -2100.00 + -3137.42, keeping the stored sign.
      assert cards_totals =~ "R$ -5.237,42"
    end

    test "renders the empty message when no balance matches the filters", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert index_live |> element("#balances-empty") |> render() =~
               "Nenhum saldo encontrado para os filtros selecionados."

      refute has_element?(index_live, "#balances-cash")
      refute has_element?(index_live, "#balances-cards")
    end

    test "groups a balance whose account was deleted with the cash accounts", %{conn: conn} do
      balance = current_balance(cash_account(), %{})
      current_balance(card_account(), %{})

      {1, _} =
        Repo.update_all(
          from(b in CashLens.Accounting.Balance, where: b.id == ^balance.id),
          set: [account_id: nil]
        )

      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert index_live |> element("#balances-cash #balances-#{balance.id}") |> render() =~
               "Conta excluída"

      refute has_element?(index_live, "#balances-cards #balances-#{balance.id}")
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

    test "rendimento creates an income transaction dated no later than today", %{
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
      assert transaction.date == today
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
      account = Accounts.get_account!(CashLens.Ownership.current_user!(), balance.account_id)

      {:ok, index_live, _html} = live(conn, ~p"/balances")
      open_modal(index_live, balance)

      html =
        index_live
        |> form("#adjust-form", %{
          "adjust" => %{"real_balance" => "150.50", "adjust_type" => "correcao"}
        })
        |> render_submit()

      assert html =~ "Saldo inicial"

      updated = Accounts.get_account!(CashLens.Ownership.current_user!(), balance.account_id)
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

      {:ok, %Transaction{}} =
        Transactions.create_transaction(%{
          account_id: balance.account_id,
          date: today,
          description: "Rendimento",
          amount: Decimal.new("30.00"),
          category_id: category.id
        })

      current =
        BalanceAdjuster.current_final_balance(
          CashLens.Repo.get!(CashLens.Users.User, CashLens.Repo.current_user_id()),
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

  describe "tenancy" do
    setup %{user: user} do
      %{a: other} = cross_tenant()
      today = Date.utc_today()
      foreign_account = account_fixture(%{user: other, name: "Foreign account"})

      foreign =
        balance_fixture(%{
          user: other,
          account_id: foreign_account.id,
          year: today.year,
          month: today.month
        })

      mine_account = account_fixture(%{user: user, name: "My account"})

      mine =
        balance_fixture(%{
          user: user,
          account_id: mine_account.id,
          year: today.year,
          month: today.month
        })

      %{other: other, foreign: foreign, mine: mine}
    end

    test "lists only the logged-in user's balances", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/balances")
      assert html =~ "My account"
      refute html =~ "Foreign account"
    end

    test "a forged adjust event for another user's account is a no-op", %{
      conn: conn,
      other: other,
      foreign: foreign
    } do
      {:ok, live, _html} = live(conn, ~p"/balances")
      html = open_modal(live, foreign)

      assert html =~ "Saldo não encontrado"
      refute has_element?(live, "#adjust-balance-modal")
      refute html =~ "Foreign account"

      CashLens.Tenancy.acting_as(other, fn ->
        assert Repo.get!(CashLens.Accounting.Balance, foreign.id) == foreign
      end)
    end
  end
end
