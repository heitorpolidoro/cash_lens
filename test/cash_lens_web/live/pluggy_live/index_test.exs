defmodule CashLensWeb.PluggyLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy

  describe "registering an item" do
    test "creating an item via the form shows it in the list", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/pluggy")

      render_click(live, "open_new_item_modal", %{})

      html =
        live
        |> form("#pluggy-item-form", item: %{item_id: "abc-123", label: "Open Finance BB"})
        |> render_submit()

      assert html =~ "Open Finance BB"
      assert Pluggy.list_items() |> Enum.map(& &1.item_id) == ["abc-123"]
    end

    test "an item with no synced accounts shows a placeholder row", %{conn: conn} do
      pluggy_item_fixture(item_id: "item-no-links", label: "Sem contas ainda")

      {:ok, _live, html} = live(conn, ~p"/pluggy")

      assert html =~ "Sem contas ainda"
      assert html =~ "Nenhuma conta sincronizada ainda"
    end

    test "item_id is required", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/pluggy")

      render_click(live, "open_new_item_modal", %{})

      html =
        live
        |> form("#pluggy-item-form", item: %{item_id: "", label: "sem id"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Pluggy.list_items() == []
    end
  end

  describe "removing an item" do
    test "confirming the modal deletes the item and its account links", %{conn: conn} do
      item = pluggy_item_fixture(item_id: "item-to-remove")

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "confirm_delete_item", %{"item_id" => item.id})
      assert html =~ "Remover Item?"

      html = render_click(live, "delete_item", %{"item_id" => item.id})

      assert html =~ "Item removido."
      refute html =~ item.label
      assert Pluggy.list_items() == []
      assert Pluggy.list_account_links_for_item(item.id) == []
      refute CashLens.Repo.get(CashLens.Pluggy.AccountLink, link.id)
    end

    test "cancelling the modal keeps the item", %{conn: conn} do
      item = pluggy_item_fixture(item_id: "item-to-keep")

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      render_click(live, "confirm_delete_item", %{"item_id" => item.id})
      html = render_click(live, "close_modal", %{})

      refute html =~ "Remover Item?"
      assert Pluggy.list_items() |> Enum.map(& &1.id) == [item.id]
    end
  end

  describe "syncing an item's accounts" do
    setup do
      System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
      System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")
      item = pluggy_item_fixture(item_id: "item-1")
      %{item: item, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    test "fetches accounts from Pluggy and lists them with an unmapped select", %{
      conn: conn,
      item: item
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "acc-1",
                  "name" => "BANCO DO BRASIL S/A",
                  "type" => "BANK",
                  "balance" => 281.03
                }
              ]
            })
        end
      end)

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "sync_accounts", %{"item_id" => item.id})

      assert html =~ "BANCO DO BRASIL S/A"
      assert html =~ "R$ 281,03"
      assert [link] = Pluggy.list_account_links_for_item(item.id)
      assert link.pluggy_account_id == "acc-1"
      assert is_nil(link.account_id)
      assert Decimal.equal?(link.pluggy_balance, Decimal.new("281.03"))
    end

    test "choosing an account in the select links it", %{conn: conn, item: item} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "acc-1",
                  "name" => "BANCO DO BRASIL S/A",
                  "type" => "BANK",
                  "balance" => 281.03
                }
              ]
            })
        end
      end)

      cash_lens_account = account_fixture(%{name: "Conta Corrente"})

      {:ok, live, _html} = live(conn, ~p"/pluggy")
      render_click(live, "sync_accounts", %{"item_id" => item.id})
      [link] = Pluggy.list_account_links_for_item(item.id)

      render_click(live, "link_account", %{
        "link_id" => link.id,
        "account_id" => cash_lens_account.id
      })

      [updated] = Pluggy.list_account_links_for_item(item.id)
      assert updated.account_id == cash_lens_account.id
    end

    test "missing credentials shows an error flash and doesn't create account links", %{
      conn: conn
    } do
      # Save current env vars and delete them
      client_id = System.get_env("PLUGGY_CLIENT_ID")
      client_secret = System.get_env("PLUGGY_CLIENT_SECRET")
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")

      # Restore them after the test
      on_exit(fn ->
        if client_id, do: System.put_env("PLUGGY_CLIENT_ID", client_id)
        if client_secret, do: System.put_env("PLUGGY_CLIENT_SECRET", client_secret)
      end)

      item = pluggy_item_fixture(item_id: "item-missing-creds")

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "sync_accounts", %{"item_id" => item.id})

      assert html =~ "não configurados"
      assert Pluggy.list_account_links_for_item(item.id) == []
    end

    test "client error surfaces a flash and doesn't create account links", %{
      conn: conn,
      item: item
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "Invalid credentials"})
      end)

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "sync_accounts", %{"item_id" => item.id})

      assert html =~ "Falha ao buscar"
      assert Pluggy.list_account_links_for_item(item.id) == []
    end
  end

  describe "syncing all items at once" do
    setup do
      System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
      System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")

      item_a = pluggy_item_fixture(item_id: "item-a")
      item_b = pluggy_item_fixture(item_id: "item-b")

      %{
        item_a: item_a,
        item_b: item_b,
        req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]
      }
    end

    test "syncs every registered item's accounts in one click", %{
      conn: conn,
      item_a: item_a,
      item_b: item_b
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/accounts" ->
            [{"itemId", item_id}] =
              conn.query_string |> URI.decode_query() |> Map.to_list()

            name = if item_id == item_a.item_id, do: "CONTA A", else: "CONTA B"

            Req.Test.json(conn, %{
              "results" => [
                %{"id" => "acc-#{item_id}", "name" => name, "type" => "BANK", "balance" => 10.0}
              ]
            })
        end
      end)

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "sync_all_items", %{})

      assert html =~ "2 item(ns) sincronizado(s)."
      assert html =~ "CONTA A"
      assert html =~ "CONTA B"
      assert [_] = Pluggy.list_account_links_for_item(item_a.id)
      assert [_] = Pluggy.list_account_links_for_item(item_b.id)
    end

    test "missing credentials shows an error flash", %{conn: conn} do
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")

      on_exit(fn ->
        System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
        System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")
      end)

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "sync_all_items", %{})

      assert html =~ "não configurados"
    end
  end
end
