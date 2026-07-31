defmodule CashLensWeb.TransactionLive.PluggyImportTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  setup do
    item = pluggy_item_fixture()
    account = account_fixture(%{name: "Conta Corrente"})

    {:ok, link} =
      Pluggy.upsert_account_link(item, %{
        pluggy_account_id: "acc-1",
        pluggy_account_name: "Conta Corrente",
        pluggy_account_type: "BANK"
      })

    {:ok, link} = Pluggy.link_account(link, account.id)

    %{item: item, account: account, link: link}
  end

  defp put_pluggy_env(_context) do
    client_id = System.get_env("PLUGGY_CLIENT_ID")
    client_secret = System.get_env("PLUGGY_CLIENT_SECRET")

    System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
    System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")

    on_exit(fn ->
      if client_id,
        do: System.put_env("PLUGGY_CLIENT_ID", client_id),
        else: System.delete_env("PLUGGY_CLIENT_ID")

      if client_secret,
        do: System.put_env("PLUGGY_CLIENT_SECRET", client_secret),
        else: System.delete_env("PLUGGY_CLIENT_SECRET")
    end)

    :ok
  end

  test "clicking Importar do Pluggy without credentials configured flashes an error", %{
    conn: conn
  } do
    client_id = System.get_env("PLUGGY_CLIENT_ID")
    client_secret = System.get_env("PLUGGY_CLIENT_SECRET")

    on_exit(fn ->
      if client_id,
        do: System.put_env("PLUGGY_CLIENT_ID", client_id),
        else: System.delete_env("PLUGGY_CLIENT_ID")

      if client_secret,
        do: System.put_env("PLUGGY_CLIENT_SECRET", client_secret),
        else: System.delete_env("PLUGGY_CLIENT_SECRET")
    end)

    System.delete_env("PLUGGY_CLIENT_ID")
    System.delete_env("PLUGGY_CLIENT_SECRET")

    {:ok, live, _html} = live(conn, ~p"/transactions")

    html = render_click(live, "import_pluggy", %{})

    assert html =~ "PLUGGY_CLIENT_ID" or html =~ "não configuradas" or
             html =~ "não configurado"
  end

  test "the button is present in the actions menu", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/transactions")

    assert has_element?(live, "button[phx-click='import_pluggy']")
  end

  test "clicking Importar do Pluggy with valid credentials imports transactions for a linked account",
       %{conn: conn, account: account} do
    put_pluggy_env(%{})

    Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
      case conn.request_path do
        "/auth" ->
          Req.Test.json(conn, %{"apiKey" => "test-key"})

        "/v2/transactions" ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "id" => "tx-1",
                "date" => "2026-07-15T00:00:00.000Z",
                "description" => "MERCADO XYZ",
                "amount" => 42.5,
                "type" => "DEBIT",
                "category" => "Supermarket"
              },
              %{
                "id" => "tx-2",
                "date" => "2026-07-16T00:00:00.000Z",
                "description" => "SALARIO",
                "amount" => 1000.0,
                "type" => "CREDIT",
                "category" => "Income"
              }
            ],
            "next" => nil
          })
      end
    end)

    {:ok, live, _html} = live(conn, ~p"/transactions")

    html = render_click(live, "import_pluggy", %{})

    assert html =~ "2 transações novas"

    assert Repo.get_by(Transaction, account_id: account.id, description: "MERCADO XYZ")
    assert Repo.get_by(Transaction, account_id: account.id, description: "SALARIO")
  end

  test "clicking Importar do Pluggy with one linked account failing still surfaces the partial failure",
       %{conn: conn, item: item, account: account} do
    put_pluggy_env(%{})

    bad_account = account_fixture(%{name: "Conta Ruim"})

    {:ok, bad_link} =
      Pluggy.upsert_account_link(item, %{
        pluggy_account_id: "acc-bad",
        pluggy_account_name: "Conta Ruim",
        pluggy_account_type: "BANK"
      })

    {:ok, _bad_link} = Pluggy.link_account(bad_link, bad_account.id)

    Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
      case conn.request_path do
        "/auth" ->
          Req.Test.json(conn, %{"apiKey" => "test-key"})

        "/v2/transactions" ->
          if conn.query_string =~ "accountId=acc-bad" do
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
          else
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "tx-1",
                  "date" => "2026-07-15T00:00:00.000Z",
                  "description" => "MERCADO XYZ",
                  "amount" => 42.5,
                  "type" => "DEBIT",
                  "category" => "Supermarket"
                }
              ],
              "next" => nil
            })
          end
      end
    end)

    {:ok, live, _html} = live(conn, ~p"/transactions")

    html = render_click(live, "import_pluggy", %{})

    assert html =~ "1 transações novas"
    assert html =~ "1 conta(s) falharam"

    assert Repo.get_by(Transaction, account_id: account.id, description: "MERCADO XYZ")
    refute Repo.get_by(Transaction, account_id: bad_account.id)
  end
end
