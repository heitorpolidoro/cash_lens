defmodule CashLens.Pluggy.ClientTest do
  use ExUnit.Case, async: true

  alias CashLens.Pluggy.Client

  setup do
    {:ok, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
  end

  describe "auth/3" do
    test "returns the api key on a 200 response", %{req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.request_path == "/auth"
        Req.Test.json(conn, %{"apiKey" => "test-key"})
      end)

      assert {:ok, "test-key"} = Client.auth("cid", "csecret", req_options)
    end

    test "returns an error tuple on a non-200 response", %{req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "invalid credentials"})
      end)

      assert {:error, {401, %{"message" => "invalid credentials"}}} =
               Client.auth("cid", "wrong", req_options)
    end
  end

  describe "list_accounts/3" do
    test "returns the results list", %{req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.request_path == "/accounts"
        assert conn.query_string =~ "itemId=item-1"

        Req.Test.json(conn, %{
          "results" => [%{"id" => "acc-1", "name" => "Conta", "type" => "BANK"}]
        })
      end)

      assert {:ok, [%{"id" => "acc-1"}]} = Client.list_accounts("api-key", "item-1", req_options)
    end
  end

  describe "list_transactions/4" do
    test "returns results from a single page when there is no next cursor", %{
      req_options: req_options
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.request_path == "/v2/transactions"
        assert conn.query_string =~ "accountId=acc-1"
        refute conn.query_string =~ "from="

        Req.Test.json(conn, %{
          "results" => [
            %{"id" => "tx-1", "date" => "2026-05-01T10:00:00.000Z"},
            %{"id" => "tx-2", "date" => "2026-05-02T10:00:00.000Z"}
          ],
          "next" => nil
        })
      end)

      assert {:ok, [%{"id" => "tx-1"}, %{"id" => "tx-2"}]} =
               Client.list_transactions("api-key", "acc-1", ~D[2026-05-01], req_options)
    end

    test "follows the cursor across pages and flattens the results", %{
      req_options: req_options
    } do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        call_number = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        case call_number do
          0 ->
            assert conn.query_string =~ "accountId=acc-1"
            refute conn.query_string =~ "after="

            Req.Test.json(conn, %{
              "results" => [%{"id" => "tx-1", "date" => "2026-05-01T10:00:00.000Z"}],
              "next" => "cursor-abc"
            })

          1 ->
            assert conn.query_string =~ "after=cursor-abc"

            Req.Test.json(conn, %{
              "results" => [%{"id" => "tx-2", "date" => "2026-05-02T10:00:00.000Z"}],
              "next" => nil
            })
        end
      end)

      assert {:ok, [%{"id" => "tx-1"}, %{"id" => "tx-2"}]} =
               Client.list_transactions("api-key", "acc-1", ~D[2026-05-01], req_options)
    end
  end
end
