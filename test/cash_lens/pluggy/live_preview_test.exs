defmodule CashLens.Pluggy.LivePreviewTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Pluggy
  alias CashLens.Pluggy.LivePreview

  setup do
    System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
    System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")

    on_exit(fn ->
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")
    end)

    %{req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
  end

  describe "fetch_all/1" do
    test "returns normalized entries for every linked account, keyed by account_id", %{
      req_options: req_options
    } do
      account = account_fixture()
      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "tx-1",
                  "date" => "2026-07-15T15:00:00.000Z",
                  "description" => "MERCADO XYZ",
                  "amount" => -42.5,
                  "type" => "DEBIT",
                  "category" => "Supermarket"
                }
              ],
              "next" => nil
            })
        end
      end)

      assert {:ok, entries_by_account} = LivePreview.fetch_all(req_options)
      assert [%LivePreview.Entry{} = entry] = entries_by_account[link.account_id]
      assert entry.id == "pluggy-preview-tx-1"
      assert entry.account_id == account.id
      assert entry.date == ~D[2026-07-15]
      assert entry.description == "MERCADO XYZ"
      assert Decimal.equal?(entry.amount, Decimal.new("-42.5"))
      assert entry.pluggy_category == "Supermarket"
    end

    test "fetches from the account's latest transaction date, not a fixed lookback", %{
      req_options: req_options
    } do
      account = account_fixture()
      transaction_fixture(%{account_id: account.id, date: ~D[2026-06-01], amount: "-10"})

      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})
        end
      end)

      {:ok, entries_by_account} = LivePreview.fetch_all(req_options)
      assert entries_by_account[link.account_id] == []
    end

    test "one account's fetch failure yields an empty list for it without affecting others", %{
      req_options: req_options
    } do
      account_a = account_fixture()
      account_b = account_fixture()
      item = pluggy_item_fixture()

      {:ok, link_a} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-a",
          pluggy_account_name: "Conta A",
          pluggy_account_type: "BANK"
        })

      {:ok, link_a} = Pluggy.link_account(link_a, account_a.id)

      {:ok, link_b} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-b",
          pluggy_account_name: "Conta B",
          pluggy_account_type: "BANK"
        })

      {:ok, link_b} = Pluggy.link_account(link_b, account_b.id)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            if conn.query_params["accountId"] == "acc-a" do
              conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
            else
              Req.Test.json(conn, %{"results" => [], "next" => nil})
            end
        end
      end)

      assert {:ok, entries_by_account} = LivePreview.fetch_all(req_options)
      assert entries_by_account[link_a.account_id] == []
      assert entries_by_account[link_b.account_id] == []
    end

    test "returns {:error, :missing_credentials} when env vars are unset" do
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")

      assert {:error, :missing_credentials} = LivePreview.fetch_all()
    end
  end
end
