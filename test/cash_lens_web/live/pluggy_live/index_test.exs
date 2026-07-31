defmodule CashLensWeb.PluggyLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy

  describe "registering an item" do
    test "creating an item via the form shows it in the list", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html =
        live
        |> form("#pluggy-item-form", item: %{item_id: "abc-123", label: "Open Finance BB"})
        |> render_submit()

      assert html =~ "Open Finance BB"
      assert Pluggy.list_items() |> Enum.map(& &1.item_id) == ["abc-123"]
    end

    test "item_id is required", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html =
        live
        |> form("#pluggy-item-form", item: %{item_id: "", label: "sem id"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Pluggy.list_items() == []
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
      assert [link] = Pluggy.list_account_links_for_item(item.id)
      assert link.pluggy_account_id == "acc-1"
      assert is_nil(link.account_id)
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
  end
end
