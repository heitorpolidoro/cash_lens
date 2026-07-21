defmodule CashLensWeb.AccountLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  describe "Atualizar com Rendimentos" do
    setup do
      category_fixture(%{name: "Rendimento"})
      account = account_fixture(%{name: "Poupança", balance: "1000.00", is_credit_card: false})
      %{account: account}
    end

    test "button is shown for non-credit-card accounts", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      assert has_element?(
               live,
               "button[phx-value-id='#{account.id}'][phx-click='open_update_balance_modal']"
             )
    end

    test "button is hidden for credit card accounts", %{conn: conn} do
      card = account_fixture(%{name: "Cartão", is_credit_card: true})
      {:ok, live, _html} = live(conn, ~p"/accounts")

      refute has_element?(
               live,
               "button[phx-value-id='#{card.id}'][phx-click='open_update_balance_modal']"
             )
    end

    test "opening the modal shows the current calculated balance", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      html = render_click(live, "open_update_balance_modal", %{"id" => account.id})

      assert html =~ "Atualizar com Rendimentos"
      assert html =~ "R$ 1.000,00"
    end

    test "positive difference creates a Rendimento transaction", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      render_click(live, "open_update_balance_modal", %{"id" => account.id})

      html =
        render_submit(live, "update_balance_with_income", %{
          "balance" => %{"new_balance" => "1050.00"}
        })

      assert html =~ "Rendimento registrado com sucesso."

      transaction = Repo.get_by!(Transaction, account_id: account.id, description: "Rendimento")
      assert Decimal.equal?(transaction.amount, Decimal.new("50.00"))
      assert transaction.date == Date.utc_today()

      category = CashLens.Categories.get_category_by_slug("rendimento")
      assert transaction.category_id == category.id
    end

    test "negative difference creates a Rendimento transaction with negative amount", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      render_click(live, "open_update_balance_modal", %{"id" => account.id})

      render_submit(live, "update_balance_with_income", %{
        "balance" => %{"new_balance" => "900.00"}
      })

      transaction = Repo.get_by!(Transaction, account_id: account.id, description: "Rendimento")
      assert Decimal.equal?(transaction.amount, Decimal.new("-100.00"))
    end

    test "zero difference creates no transaction", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      render_click(live, "open_update_balance_modal", %{"id" => account.id})

      html =
        render_submit(live, "update_balance_with_income", %{
          "balance" => %{"new_balance" => "1000.00"}
        })

      assert html =~ "Nenhuma diferença a registrar."
      refute Repo.get_by(Transaction, account_id: account.id, description: "Rendimento")
    end

    test "invalid balance keeps the modal open without creating a transaction", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      render_click(live, "open_update_balance_modal", %{"id" => account.id})

      html =
        render_submit(live, "update_balance_with_income", %{
          "balance" => %{"new_balance" => ""}
        })

      assert html =~ "Atualizar com Rendimentos"
      refute Repo.get_by(Transaction, account_id: account.id, description: "Rendimento")
    end
  end
end
