defmodule CashLens.Pluggy.SyncTest do
  use CashLens.DataCase, async: false

  import Ecto.Query
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.PluggyFixtures

  alias CashLens.CreditCards
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Sync
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  describe "normalize_amount/2 — sign conversion" do
    test "BANK + DEBIT becomes negative" do
      assert Decimal.equal?(
               Sync.normalize_amount("BANK", %{"amount" => 150.0, "type" => "DEBIT"}),
               Decimal.new("-150.0")
             )
    end

    test "BANK + CREDIT stays positive" do
      assert Decimal.equal?(
               Sync.normalize_amount("BANK", %{"amount" => 150.0, "type" => "CREDIT"}),
               Decimal.new("150.0")
             )
    end

    test "CREDIT account inverts Pluggy's positive-means-expense sign" do
      assert Decimal.equal?(
               Sync.normalize_amount("CREDIT", %{"amount" => 89.9}),
               Decimal.new("-89.9")
             )
    end

    test "CREDIT account: a Pluggy negative (payment/credit) becomes positive" do
      assert Decimal.equal?(
               Sync.normalize_amount("CREDIT", %{"amount" => -500.0}),
               Decimal.new("500.0")
             )
    end
  end

  describe "sync_account_link/2" do
    setup do
      category_fixture(%{name: "Rendimento"})
      item = pluggy_item_fixture()
      account = account_fixture(%{name: "Conta Corrente", is_credit_card: false})

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta Corrente",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      %{link: link, account: account, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    test "creates a transaction per Pluggy transaction with the normalized amount", %{
      link: link,
      account: account,
      req_options: req_options
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
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
      end)

      assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      transaction = Repo.get_by!(Transaction, account_id: account.id, description: "MERCADO XYZ")
      assert Decimal.equal?(transaction.amount, Decimal.new("-42.5"))
      assert transaction.date == ~D[2026-07-15]
      assert transaction.pluggy_category == "Supermarket"
    end

    test "re-syncing the same transactions counts them as skipped, not duplicated", %{
      link: link,
      req_options: req_options
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
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
      end)

      assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert Repo.aggregate(Transaction, :count) == 1
    end

    test "updates last_synced_at after a successful sync", %{link: link, req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{"results" => [], "next" => nil})
      end)

      assert is_nil(link.last_synced_at)
      assert {:ok, _} = Sync.sync_account_link(link, "fake-api-key", req_options)

      updated = Repo.get!(CashLens.Pluggy.AccountLink, link.id)
      assert %DateTime{} = updated.last_synced_at
    end
  end

  describe "sync_account_link/2 for a CREDIT account — statement find-or-update" do
    setup do
      item = pluggy_item_fixture()
      account = account_fixture(%{name: "Ourocard", is_credit_card: true})

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "card-1",
          pluggy_account_name: "OUROCARD",
          pluggy_account_type: "CREDIT"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)
      link = CashLens.Repo.preload(link, :pluggy_item)

      %{link: link, account: account, item: item}
    end

    test "creates a statement on first sync and updates it (not a second row) on a later sync",
         %{link: link, account: account, item: item} do
      req_options = [plug: {Req.Test, CashLens.Pluggy.Client}]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/v2/transactions" ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "card-1",
                  "balance" => 1200.0,
                  "creditData" => %{
                    "balanceDueDate" => "2026-08-10",
                    "balanceCloseDate" => "2026-08-03"
                  }
                }
              ]
            })
        end
      end)

      assert {:ok, _} = Sync.sync_account_link(link, "fake-api-key", req_options)

      statement = CreditCards.get_statement_by_account_and_competencia(account.id, ~D[2026-08-01])
      assert Decimal.equal?(statement.total_a_pagar, Decimal.new("1200.0"))
      assert statement.due_date == ~D[2026-08-10]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/v2/transactions" ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "card-1",
                  "balance" => 1450.0,
                  "creditData" => %{
                    "balanceDueDate" => "2026-08-10",
                    "balanceCloseDate" => "2026-08-03"
                  }
                }
              ]
            })
        end
      end)

      refreshed_link =
        Repo.get!(CashLens.Pluggy.AccountLink, link.id) |> Repo.preload(:pluggy_item)

      assert {:ok, _} = Sync.sync_account_link(refreshed_link, "fake-api-key", req_options)

      statements =
        CashLens.Repo.all(
          from s in CashLens.CreditCards.Statement,
            where: s.account_id == ^account.id and s.competencia == ^~D[2026-08-01]
        )

      assert length(statements) == 1
      assert Decimal.equal?(hd(statements).total_a_pagar, Decimal.new("1450.0"))

      _ = item
    end
  end

  describe "sync_account_link/2 — sync window" do
    setup do
      item = pluggy_item_fixture()
      account = account_fixture(%{name: "Conta Corrente"})

      {:ok, _link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta Corrente",
          pluggy_account_type: "BANK"
        })

      %{item: item, account: account, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    # Note: CashLens.Pluggy.Client (Task 2) does not send `from` as a
    # server-side query param — the real Pluggy API rejects it. Instead it
    # fetches the full transaction history and filters to `date >=
    # from_date` client-side (see lib/cash_lens/pluggy/client.ex). So the
    # only way to observe Sync's `from_date` computation end-to-end is via
    # that filtering behavior: seed one transaction on/after the expected
    # boundary and one before it, and assert only the former survives.
    test "with last_synced_at nil, only imports transactions from the last 90 days", %{
      account: account,
      item: item,
      req_options: req_options
    } do
      {:ok, link} =
        Pluggy.link_account(hd(Pluggy.list_account_links_for_item(item.id)), account.id)

      expected_from = Date.add(Date.utc_today(), -90)

      in_window_date =
        expected_from |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

      out_of_window_date =
        expected_from
        |> Date.add(-1)
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
        |> DateTime.to_iso8601()

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "id" => "in-window",
              "date" => in_window_date,
              "description" => "IN WINDOW",
              "amount" => 10.0,
              "type" => "DEBIT"
            },
            %{
              "id" => "out-of-window",
              "date" => out_of_window_date,
              "description" => "OUT OF WINDOW",
              "amount" => 20.0,
              "type" => "DEBIT"
            }
          ],
          "next" => nil
        })
      end)

      assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert Repo.get_by(Transaction, account_id: account.id, description: "IN WINDOW")
      refute Repo.get_by(Transaction, account_id: account.id, description: "OUT OF WINDOW")
    end

    test "with last_synced_at set, only imports transactions from that date on", %{
      account: account,
      item: item,
      req_options: req_options
    } do
      {:ok, link} =
        Pluggy.link_account(hd(Pluggy.list_account_links_for_item(item.id)), account.id)

      past = DateTime.new!(~D[2026-05-10], ~T[00:00:00], "Etc/UTC")

      link =
        link
        |> Ecto.Changeset.change(last_synced_at: past)
        |> Repo.update!()

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "id" => "in-window",
              "date" => "2026-05-10T00:00:00.000Z",
              "description" => "IN WINDOW",
              "amount" => 10.0,
              "type" => "DEBIT"
            },
            %{
              "id" => "out-of-window",
              "date" => "2026-05-09T00:00:00.000Z",
              "description" => "OUT OF WINDOW",
              "amount" => 20.0,
              "type" => "DEBIT"
            }
          ],
          "next" => nil
        })
      end)

      assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert Repo.get_by(Transaction, account_id: account.id, description: "IN WINDOW")
      refute Repo.get_by(Transaction, account_id: account.id, description: "OUT OF WINDOW")
    end
  end

  describe "sync_all/0" do
    test "returns {:error, :missing_credentials} when env vars are unset" do
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")

      assert Sync.sync_all() == {:error, :missing_credentials}
    end

    test "one account failing does not stop the others from syncing" do
      System.put_env("PLUGGY_CLIENT_ID", "cid")
      System.put_env("PLUGGY_CLIENT_SECRET", "csecret")

      item = pluggy_item_fixture()
      good_account = account_fixture(%{name: "Boa"})
      bad_account = account_fixture(%{name: "Ruim"})

      {:ok, good_link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "good",
          pluggy_account_name: "Boa",
          pluggy_account_type: "BANK"
        })

      {:ok, good_link} = Pluggy.link_account(good_link, good_account.id)

      {:ok, bad_link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "bad",
          pluggy_account_name: "Ruim",
          pluggy_account_type: "BANK"
        })

      {:ok, bad_link} = Pluggy.link_account(bad_link, bad_account.id)

      # retry: false — the 500 below is a deliberate, permanent failure for
      # "bad", not a transient error; without this Req's default retry
      # policy retries it 3x with backoff, which just slows the test down
      # and spams warning logs without changing what's being verified.
      req_options = [plug: {Req.Test, CashLens.Pluggy.Client}, retry: false]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            if conn.query_string =~ "accountId=bad" do
              conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
            else
              Req.Test.json(conn, %{"results" => [], "next" => nil})
            end
        end
      end)

      results = Sync.sync_all(req_options)

      {_link, good_result} = Enum.find(results, fn {link, _} -> link.id == good_link.id end)
      {_link, bad_result} = Enum.find(results, fn {link, _} -> link.id == bad_link.id end)

      assert good_result == {:ok, %{created: 0, skipped: 0, errors: 0}}
      assert {:error, _reason} = bad_result
    end

    test "a CREDIT account with null creditData does not crash the batch — other accounts still sync" do
      System.put_env("PLUGGY_CLIENT_ID", "cid")
      System.put_env("PLUGGY_CLIENT_SECRET", "csecret")

      item = pluggy_item_fixture()
      bank_account = account_fixture(%{name: "Banco", is_credit_card: false})
      credit_account = account_fixture(%{name: "Cartao", is_credit_card: true})

      {:ok, bank_link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "bank-1",
          pluggy_account_name: "Banco",
          pluggy_account_type: "BANK"
        })

      {:ok, bank_link} = Pluggy.link_account(bank_link, bank_account.id)

      {:ok, credit_link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "credit-1",
          pluggy_account_name: "Cartao",
          pluggy_account_type: "CREDIT"
        })

      {:ok, credit_link} = Pluggy.link_account(credit_link, credit_account.id)

      req_options = [plug: {Req.Test, CashLens.Pluggy.Client}, retry: false]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{"id" => "credit-1", "balance" => 100.0, "creditData" => nil}
              ]
            })
        end
      end)

      results = Sync.sync_all(req_options)

      {_link, bank_result} = Enum.find(results, fn {link, _} -> link.id == bank_link.id end)
      {_link, credit_result} = Enum.find(results, fn {link, _} -> link.id == credit_link.id end)

      assert bank_result == {:ok, %{created: 0, skipped: 0, errors: 0}}
      assert credit_result == {:ok, %{created: 0, skipped: 0, errors: 0}}
    end
  end
end
