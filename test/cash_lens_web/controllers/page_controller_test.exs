defmodule CashLensWeb.PageControllerTest do
  use CashLensWeb.ConnCase

  import CashLens.AccountsFixtures
  import CashLens.AccountingFixtures
  import CashLens.TransactionsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.FakeLivePreviewCache

  describe "GET / with live Pluggy data" do
    setup do
      Application.put_env(:cash_lens, :pluggy_live_preview_cache, FakeLivePreviewCache)
      FakeLivePreviewCache.set_entries(%{})
      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})
      on_exit(fn -> Application.delete_env(:cash_lens, :pluggy_live_preview_cache) end)
      :ok
    end

    test "a linked account's Saldo Atual uses pluggy_balance directly, ignoring the persisted balance and its own live entries",
         %{conn: conn} do
      account = account_fixture()

      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      item = pluggy_item_fixture()

      {:ok, link} =
        CashLens.Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-#{account.id}",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK",
          pluggy_balance: "812.34"
        })

      {:ok, _link} = CashLens.Pluggy.link_account(link, account.id)

      # A live entry on this same linked account must not also be added on
      # top of pluggy_balance — pluggy_balance already reflects the bank's
      # current balance, so adding this would double-count it.
      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-dash-linked",
        account_id: account.id,
        date: Date.utc_today(),
        description: "COMPRA QUALQUER",
        amount: Decimal.new("-30.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "R$ 812,34"
      refute html =~ "R$ 500,00"
      refute html =~ "R$ 782,34"
    end

    test "an account with no Pluggy link, or no stored pluggy_balance, keeps the persisted-balance + live-entries calculation",
         %{conn: conn} do
      account = account_fixture()

      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-dash-unlinked",
        account_id: account.id,
        date: Date.utc_today(),
        description: "COMPRA QUALQUER",
        amount: Decimal.new("-30.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "R$ 470,00"
    end

    test "the summary card follows only the latest persisted transaction, ignoring live-entry dates",
         %{conn: conn} do
      account = account_fixture()

      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        description: "Compra março",
        amount: "-50.00",
        date: ~D[2026-03-10]
      })

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-dash-3",
        account_id: account.id,
        date: ~D[2026-04-05],
        description: "COMPRA ABRIL",
        amount: Decimal.new("-30.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # The summary month is pinned to the latest persisted transaction
      # (March) — a live entry in a later month must not pull it forward,
      # and the live expense must not appear in Despesas.
      assert html =~ "(Março)"
      refute html =~ "(Abril)"
      refute html =~ "R$ 30,00"
    end

    test "a live entry for the current month bumps Saldo Atual but not Receitas/Despesas",
         %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-dash-1",
        account_id: account.id,
        date: today,
        description: "COMPRA TEMPORARIA",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # 500,00 (persisted balance) - 25,00 (live entry) = 475,00
      assert html =~ "R$ 475,00"
      # Despesas no longer picks up live entries — only imported transactions.
      refute html =~ "R$ 25,00"
      # The dashboard no longer carries the live-Pluggy badge.
      refute html =~ "dados temporários do Pluggy"
    end

    test "no live entries: figures are unaffected", %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "R$ 500,00"
      refute html =~ "dados temporários do Pluggy"
    end

    test "a live entry from a different month does not affect Receitas/Despesas but still bumps Saldo Atual",
         %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      last_month = Date.add(Date.beginning_of_month(today), -1)

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-dash-2",
        account_id: account.id,
        date: last_month,
        description: "COMPRA MES PASSADO",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # Saldo Atual still includes it (it affects the current total regardless of date)...
      assert html =~ "R$ 475,00"
      # ...but Despesas (this month) does not.
      refute html =~ "R$ 25,00"
    end
  end

  test "GET / with data", %{conn: conn} do
    account = account_fixture()
    balance_fixture(%{account_id: account.id, year: 2026, month: 4, final_balance: "500.00"})
    transaction_fixture(%{account_id: account.id, amount: "100.00", date: ~D[2026-04-01]})

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
    assert html_response(conn, 200) =~ account.name
    # Monthly summary income/expenses should be present (based on seeds/fixtures logic)
  end

  test "GET / with historical data", %{conn: conn} do
    account = account_fixture()
    # Past month balance
    balance_fixture(%{account_id: account.id, year: 2026, month: 3, final_balance: "400.00"})
    # Create another month to test missing historical summary fallback
    balance_fixture(%{account_id: account.id, year: 2026, month: 2, final_balance: "400.00"})

    import CashLens.CategoriesFixtures
    category_fixed = category_fixture(%{type: "fixed", name: "Fixed Cat"})
    category_var = category_fixture(%{type: "variable", name: "Var Cat"})

    transaction_fixture(%{
      account_id: account.id,
      amount: "-100.00",
      date: ~D[2026-03-01],
      category_id: category_fixed.id
    })

    transaction_fixture(%{
      account_id: account.id,
      amount: "-50.00",
      date: ~D[2026-03-02],
      category_id: category_var.id
    })

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  test "GET / with no data renders the dashboard", %{conn: conn} do
    # No accounts/balances/transactions: exercises the empty-state branches.
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  describe "GET / dashboard layout" do
    test "renders the four KPI cards, the consolidated chart and the Minhas Contas card", %{
      conn: conn
    } do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Saldo Atual"
      assert html =~ "Receitas ("
      assert html =~ "Despesas ("
      assert html =~ "Balanço ("
      assert html =~ "Evolução Financeira Consolidada"
      assert html =~ ~s(id="balanceChart")
      assert html =~ "Minhas Contas"
      assert html =~ "Total em Contas"
      assert html =~ account.name
    end

    test "Minhas Contas totals the listed accounts' current balances", %{conn: conn} do
      today = Date.utc_today()

      for final <- ["500.00", "250.00"] do
        account = account_fixture()

        balance_fixture(%{
          account_id: account.id,
          year: today.year,
          month: today.month,
          final_balance: final
        })
      end

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "R$ 500,00"
      assert html =~ "R$ 250,00"
      # Consolidated total in the card footer.
      assert html =~ "R$ 750,00"
    end

    test "drops the 12-month history table and the fixed/variable category charts", %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{account_id: account.id, year: today.year, month: today.month})

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "Histórico Mensal"
      refute html =~ "Balanço 3 meses"
      refute html =~ "Balanço 6 meses"
      refute html =~ "Balanço 12 meses"
      refute html =~ "fixedChart"
      refute html =~ "variableChart"
      refute html =~ "Custo de Vida"
      refute html =~ "Estilo de Vida"
    end

    test "chart data holds the last 12 real months ending in the current one, with no projections",
         %{conn: conn} do
      conn = get(conn, ~p"/")
      today = Date.utc_today()

      refute conn.assigns.chart_data =~ "is_projection"

      series = Jason.decode!(conn.assigns.chart_data)
      assert length(series) == 12

      assert List.last(series)["year"] == today.year
      assert List.last(series)["month"] == today.month

      for item <- series do
        assert item["year"] * 12 + item["month"] <= today.year * 12 + today.month
      end
    end

    test "assigns are limited to what the simplified dashboard needs", %{conn: conn} do
      conn = get(conn, ~p"/")

      for key <- [
            :total_balance,
            :monthly_income,
            :monthly_expenses,
            :monthly_balance,
            :summary_month,
            :chart_data,
            :accounts
          ] do
        assert Map.has_key?(conn.assigns, key)
      end

      for key <- [
            :fixed_data,
            :variable_data,
            :historical,
            :trailing_balance_3m,
            :trailing_balance_6m,
            :trailing_balance_12m,
            :has_live_balance?
          ] do
        refute Map.has_key?(conn.assigns, key)
      end
    end
  end

  test "GET /.well-known/appspecific/com.chrome.devtools.json", %{conn: conn} do
    conn = get(conn, "/.well-known/appspecific/com.chrome.devtools.json")
    assert response(conn, 204) == ""
  end
end
