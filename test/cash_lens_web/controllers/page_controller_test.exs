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
      # The badge still shows (Saldo Atual and Balanço both reflect the live delta).
      assert html =~ "Atualizado com dados temporários do Pluggy"
    end

    test "no live entries: no badge, figures are unaffected", %{conn: conn} do
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
      refute html =~ "Atualizado com dados temporários do Pluggy"
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
    # No accounts/balances/transactions: exercises the empty-history projection fallback.
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  test "GET / factors active installments into projections", %{conn: conn} do
    account = account_fixture()
    today = Date.utc_today()

    balance_fixture(%{
      account_id: account.id,
      year: today.year,
      month: today.month,
      final_balance: "1000.00"
    })

    # Active group: starts this month, spans into the projected months.
    {:ok, _group} =
      CashLens.Installments.create_installment_group(%{
        description_pattern: "PROJ (6x)",
        total_amount: "600.00",
        installments: 6,
        start_date: Date.new!(today.year, today.month, 1)
      })

    # A group with no total_amount exercises the nil branch of the projection helper.
    {:ok, _g2} =
      CashLens.Installments.create_installment_group(%{
        description_pattern: "SEM VALOR (3x)",
        installments: 3,
        start_date: Date.new!(today.year, today.month, 1)
      })

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  test "GET /.well-known/appspecific/com.chrome.devtools.json", %{conn: conn} do
    conn = get(conn, "/.well-known/appspecific/com.chrome.devtools.json")
    assert response(conn, 204) == ""
  end
end
