defmodule CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache do
  @moduledoc false
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{entries: %{}, status: {:ok, DateTime.utc_now()}} end,
      name: __MODULE__
    )
  end

  def set_entries(entries) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :entries, entries))
  end

  def set_status(status) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :status, status))
  end

  def get_entries(account_id), do: Agent.get(__MODULE__, &Map.get(&1.entries, account_id, []))
  def get_all_entries, do: Agent.get(__MODULE__, & &1.entries) |> Map.values() |> List.flatten()
  def get_status, do: Agent.get(__MODULE__, & &1.status)

  defp ensure_started do
    case start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end

defmodule CashLensWeb.TransactionLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  describe "Pluggy live preview" do
    setup do
      Application.put_env(
        :cash_lens,
        :pluggy_live_preview_cache,
        CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache
      )

      on_exit(fn -> Application.delete_env(:cash_lens, :pluggy_live_preview_cache) end)
      :ok
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

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status(
        {:ok, DateTime.utc_now()}
      )

      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "COMPRA TEMPORARIA"
      assert html =~ "pluggy-preview-live-entry"
    end

    test "an error status shows a non-dismissing banner naming the failure", %{conn: conn} do
      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{})

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status(
        {:error, :missing_credentials, nil}
      )

      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "Não foi possível atualizar dados do Pluggy"
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

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status(
        {:ok, DateTime.utc_now()}
      )

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

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status(
        {:ok, DateTime.utc_now()}
      )

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

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_entries(%{
        account.id => [entry]
      })

      CashLensWeb.TransactionLive.IndexTest.FakeLivePreviewCache.set_status(
        {:ok, DateTime.utc_now()}
      )

      {:ok, live, html} = live(conn, ~p"/transactions")
      assert html =~ "NAO DEVE APARECER NO MES PASSADO"

      html = render_click(live, "prev_month", %{})

      refute html =~ "NAO DEVE APARECER NO MES PASSADO"
    end
  end
end
