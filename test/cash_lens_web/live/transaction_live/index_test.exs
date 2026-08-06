defmodule CashLensWeb.TransactionLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy
  alias CashLens.FakeLivePreviewCache

  describe "Pluggy live preview" do
    setup do
      Application.put_env(
        :cash_lens,
        :pluggy_live_preview_cache,
        FakeLivePreviewCache
      )

      # The fake is a globally-named Agent that outlives individual tests —
      # reset it so no test inherits another's entries or status.
      FakeLivePreviewCache.set_entries(%{})
      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      on_exit(fn -> Application.delete_env(:cash_lens, :pluggy_live_preview_cache) end)
      :ok
    end

    # The error banner only shows for accounts that are actually linked to
    # Pluggy, so tests exercising it need a linked account.
    defp link_account_to_pluggy(account) do
      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-#{System.unique_integer([:positive])}",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)
      link
    end

    test "a live entry for the current account renders with the temporary-row marker and sums into the total",
         %{conn: conn} do
      account = account_fixture()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-1",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "COMPRA TEMPORARIA",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "COMPRA TEMPORARIA"
      assert html =~ "pluggy-preview-live-entry"
    end

    test "a live entry renders before older real transactions, in date order", %{conn: conn} do
      account = account_fixture()

      older_transaction =
        transaction_fixture(%{
          account_id: account.id,
          date: ~D[2026-08-01],
          description: "TRANSACAO ANTIGA"
        })

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-order",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "COMPRA MAIS RECENTE",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})
      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, _live, html} = live(conn, ~p"/transactions")

      live_index = :binary.match(html, "COMPRA MAIS RECENTE") |> elem(0)
      real_index = :binary.match(html, older_transaction.description) |> elem(0)

      assert live_index < real_index
    end

    test "a real failure after a previous success shows a banner in plain Portuguese", %{
      conn: conn
    } do
      link_account_to_pluggy(account_fixture())
      FakeLivePreviewCache.set_entries(%{})

      FakeLivePreviewCache.set_status({:error, {:exception, "boom"}, ~U[2026-08-05 12:00:00Z]})

      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "Não foi possível atualizar dados do Pluggy"
      assert html =~ "erro inesperado"
      # Never a raw Elixir term in user-facing copy.
      refute html =~ ":exception"
    end

    test "no banner at all when no account is linked to Pluggy", %{conn: conn} do
      FakeLivePreviewCache.set_entries(%{})
      FakeLivePreviewCache.set_status({:error, :missing_credentials, nil})

      {:ok, _live, html} = live(conn, ~p"/transactions")

      refute html =~ "Não foi possível atualizar dados do Pluggy"
    end

    test "no banner for un-configured credentials or a first fetch that hasn't landed", %{
      conn: conn
    } do
      link_account_to_pluggy(account_fixture())
      FakeLivePreviewCache.set_entries(%{})

      for reason <- [:missing_credentials, :not_yet_fetched] do
        FakeLivePreviewCache.set_status({:error, reason, nil})
        {:ok, _live, html} = live(conn, ~p"/transactions")
        refute html =~ "Não foi possível atualizar dados do Pluggy"
      end
    end

    test "the banner disappears once the cache status returns to :ok", %{conn: conn} do
      link_account_to_pluggy(account_fixture())
      FakeLivePreviewCache.set_entries(%{})
      FakeLivePreviewCache.set_status({:error, {:exception, "boom"}, ~U[2026-08-05 12:00:00Z]})

      {:ok, live, html} = live(conn, ~p"/transactions")
      assert html =~ "Não foi possível atualizar dados do Pluggy"

      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})
      html = render_patch(live, ~p"/transactions?search=")

      refute html =~ "Não foi possível atualizar dados do Pluggy"
    end

    test "live entries are excluded when a category filter is active", %{conn: conn} do
      account = account_fixture()
      category = category_fixture()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-2",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "NAO DEVE APARECER",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, live, _html} = live(conn, ~p"/transactions")
      html = render_patch(live, ~p"/transactions?category_id=#{category.id}")

      refute html =~ "NAO DEVE APARECER"
    end

    test "a live entry's (negative) amount is added to the displayed Despesas total as a positive value",
         %{conn: conn} do
      account = account_fixture()

      _db_tx =
        transaction_fixture(
          account_id: account.id,
          description: "TESTE-SUMMARY compra",
          amount: "-10.00",
          date: ~D[2026-08-05]
        )

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-3",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "TESTE-SUMMARY live",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, live, _html} = live(conn, ~p"/transactions")
      # "search" is a filter live entries can structurally satisfy, so it stays
      # compatible while also flipping `filters_active?` so the summary cards
      # render actual figures instead of the "—" placeholder.
      html = render_patch(live, ~p"/transactions?search=TESTE-SUMMARY")

      # DB expense (R$10,00, already stored as a positive "Despesas" figure by
      # Transactions.get_filtered_summary/1) plus the live entry's R$25,00
      # (a negative amount, which must be added as a positive contribution to
      # "Despesas" rather than subtracted) = R$35,00.
      assert html =~ "R$ 35,00"
    end

    test "live entries do not leak into a different month's view", %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-4",
        account_id: account.id,
        date: today,
        description: "NAO DEVE APARECER NO MES PASSADO",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, live, html} = live(conn, ~p"/transactions")
      assert html =~ "NAO DEVE APARECER NO MES PASSADO"

      html = render_click(live, "prev_month", %{})

      refute html =~ "NAO DEVE APARECER NO MES PASSADO"
    end

    test "live entries are excluded when an amount filter is active", %{conn: conn} do
      account = account_fixture()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-5",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "NAO DEVE APARECER COM FILTRO DE VALOR",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})
      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, live, html} = live(conn, ~p"/transactions")
      assert html =~ "NAO DEVE APARECER COM FILTRO DE VALOR"

      html = render_patch(live, ~p"/transactions?amount=-25.00")

      refute html =~ "NAO DEVE APARECER COM FILTRO DE VALOR"
    end

    test "live entries are absent on page 2", %{conn: conn} do
      account = account_fixture()

      entry = %CashLens.Pluggy.LivePreview.Entry{
        id: "pluggy-preview-live-6",
        account_id: account.id,
        date: ~D[2026-08-05],
        description: "SO NA PRIMEIRA PAGINA",
        amount: Decimal.new("-25.00")
      }

      FakeLivePreviewCache.set_entries(%{account.id => [entry]})
      FakeLivePreviewCache.set_status({:ok, DateTime.utc_now()})

      {:ok, live, html} = live(conn, ~p"/transactions")
      assert html =~ "SO NA PRIMEIRA PAGINA"

      # Page 2 appends to the stream; it must not re-insert the live entry.
      html = render_click(live, "load-more", %{})

      # Exactly one occurrence — the one page 1 put there, not a duplicate.
      assert html |> String.split("SO NA PRIMEIRA PAGINA") |> length() == 2
    end
  end
end
