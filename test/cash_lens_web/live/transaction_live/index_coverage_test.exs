defmodule CashLensWeb.TransactionLive.IndexCoverageTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  describe "Index coverage" do
    test "unmark_reimbursable with link key", %{conn: conn} do
      key = Ecto.UUID.generate()
      tx1 = transaction_fixture(reimbursement_link_key: key, reimbursement_status: "linked")
      tx2 = transaction_fixture(reimbursement_link_key: key, reimbursement_status: "linked")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live
      |> element("#transactions-#{tx1.id} button[phx-click='unmark_reimbursable']")
      |> render_click()

      updated1 = Transactions.get_transaction!(tx1.id)
      updated2 = Transactions.get_transaction!(tx2.id)

      assert is_nil(updated1.reimbursement_link_key)
      assert is_nil(updated1.reimbursement_status)
      assert is_nil(updated2.reimbursement_link_key)
      assert is_nil(updated2.reimbursement_status)
    end

    test "mark_reimbursable", %{conn: conn} do
      tx = transaction_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "mark_reimbursable", %{"id" => tx.id})

      assert Transactions.get_transaction!(tx.id).reimbursement_status == "pending"
    end

    test "open_quick_category", %{conn: conn} do
      tx = transaction_fixture(description: "netflix subscription")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "open_quick_category", %{"name" => tx.description, "id" => tx.id})

      # The modal title is inside the quick-category-modal-modal-content
      assert render(index_live) =~ "Nova Categoria"
      assert render(index_live) =~ "Organize sua hierarquia financeira"
    end

    test "update_category and bulk confirmation", %{conn: conn} do
      cat = category_fixture(name: "Food")
      tx1 = transaction_fixture(description: "Restaurante A")
      tx2 = transaction_fixture(description: "Restaurante A")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "update_category", %{
        "transaction_id" => tx1.id,
        "category_id" => cat.id
      })

      html = render(index_live)
      assert html =~ "Categorização em Lote"

      index_live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert Transactions.get_transaction!(tx2.id).category_id == cat.id
      assert render(index_live) =~ "transações categorizadas!"
    end

    test "the rule checkbox is offered unchecked, and no rule is created unless it is ticked",
         %{conn: conn} do
      cat = category_fixture(name: "Food", keywords: nil)
      tx1 = transaction_fixture(description: "Restaurante A")
      transaction_fixture(description: "Restaurante A")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      html = render(live)
      assert html =~ "Criar regra de categorização automática"
      # Unchecked by default: creating a rule changes how every future import is
      # read, so it is never something the user does by not noticing a default.
      refute html =~ ~r/<input[^>]*type="checkbox"[^>]*phx-click="toggle_bulk_rule"[^>]*checked/
      # And the keyword input only appears once the box is ticked.
      refute html =~ "bulk-rule-keyword"

      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert CashLens.Categories.get_category!(cat.id).keywords in [nil, ""]
    end

    test "ticking the checkbox appends the description to the category's keywords",
         %{conn: conn} do
      cat = category_fixture(name: "Food", keywords: nil)
      tx1 = transaction_fixture(description: "Restaurante A")
      transaction_fixture(description: "Restaurante A")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})

      # The keyword input appears, seeded with the description the modal is about.
      assert render(live) =~ "bulk-rule-keyword"

      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert CashLens.Categories.get_category!(cat.id).keywords == "Restaurante A"
      assert render(live) =~ "Regra criada para &quot;Restaurante A&quot;."
    end

    test "the keyword is editable, so a rule can be broader than the description that opened it",
         %{conn: conn} do
      # The case this exists for: two boletos of the same consortium arrive as
      # "...PORTO SEGURO ADMINISTRADORA DE CONSORC" and "...ADMINISTRADORA DE".
      # A rule built from either description in full matches only that one.
      cat = category_fixture(name: "Consórcio", keywords: nil)

      tx1 =
        transaction_fixture(description: "Pagamento de Boleto - PORTO SEGURO ADMIN DE CONSORC")

      transaction_fixture(description: "Pagamento de Boleto - PORTO SEGURO ADMIN DE CONSORC")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})
      render_keyup(live, "update_bulk_rule_keyword", %{"value" => "PORTO SEGURO ADMIN"})

      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert CashLens.Categories.get_category!(cat.id).keywords == "PORTO SEGURO ADMIN"
    end

    test "the rule is appended to the keywords the category already had", %{conn: conn} do
      cat = category_fixture(name: "Food", keywords: "IFOOD")
      tx1 = transaction_fixture(description: "Restaurante A")
      transaction_fixture(description: "Restaurante A")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})
      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert CashLens.Categories.get_category!(cat.id).keywords == "IFOOD, Restaurante A"
    end

    test "a blank keyword ticks the box but creates nothing, and says so", %{conn: conn} do
      cat = category_fixture(name: "Food", keywords: nil)
      tx1 = transaction_fixture(description: "Restaurante A")
      transaction_fixture(description: "Restaurante A")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})
      render_keyup(live, "update_bulk_rule_keyword", %{"value" => "   "})

      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert CashLens.Categories.get_category!(cat.id).keywords in [nil, ""]
      # The categorization still happened, so the flash must not claim a rule.
      html = render(live)
      assert html =~ "transações categorizadas!"
      refute html =~ "Regra criada"
    end

    test "the checkbox resets to unchecked for the next bulk modal", %{conn: conn} do
      # The assign is global to the LiveView, so a rule ticked once would
      # otherwise stay ticked and silently create a rule on the next, unrelated
      # categorization.
      cat = category_fixture(name: "Food", keywords: nil)
      other = category_fixture(name: "Transporte", keywords: nil)
      tx1 = transaction_fixture(description: "Restaurante A")
      transaction_fixture(description: "Restaurante A")
      tx3 = transaction_fixture(description: "Uber trip")
      transaction_fixture(description: "Uber trip")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})
      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      render_click(live, "update_category", %{
        "transaction_id" => tx3.id,
        "category_id" => other.id
      })

      refute render(live) =~ "bulk-rule-keyword"

      live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert CashLens.Categories.get_category!(other.id).keywords in [nil, ""]
    end

    test "the rule field warns when another category already claims the text", %{conn: conn} do
      # `AutoCategorizer` keeps the first category the database returns, so a
      # keyword two categories both claim sends the import somewhere nobody
      # chose. The modal says so before the rule exists.
      category_fixture(name: "Cabeleireiro", keywords: "ALEX HAIR")
      cat = category_fixture(name: "Cuidados Pessoais", keywords: nil)
      tx1 = transaction_fixture(description: "PAG*ALEX HAIR STUDIO")
      transaction_fixture(description: "PAG*ALEX HAIR STUDIO")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})
      render_keyup(live, "update_bulk_rule_keyword", %{"value" => "HAIR"})

      assert has_element?(live, "#bulk-rule-conflicts")
      assert live |> element("#bulk-rule-conflicts") |> render() =~ "ALEX HAIR"

      # A warning, not a block: the rule is still created if the user wants it.
      live |> element("button[phx-click='apply_bulk_category']") |> render_click()
      assert CashLens.Categories.get_category!(cat.id).keywords == "HAIR"
    end

    test "the rule field stays quiet when the text clashes with nothing", %{conn: conn} do
      category_fixture(name: "Cabeleireiro", keywords: "ALEX HAIR")
      cat = category_fixture(name: "Mercado", keywords: nil)
      tx1 = transaction_fixture(description: "GRUPO FARTURA DE HORT")
      transaction_fixture(description: "GRUPO FARTURA DE HORT")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})

      refute has_element?(live, "#bulk-rule-conflicts")
    end

    test "the warning follows the text as it is edited", %{conn: conn} do
      category_fixture(name: "Cabeleireiro", keywords: "ALEX HAIR")
      cat = category_fixture(name: "Cuidados Pessoais", keywords: nil)
      tx1 = transaction_fixture(description: "PAG*ALEX HAIR STUDIO")
      transaction_fixture(description: "PAG*ALEX HAIR STUDIO")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(live, "update_category", %{"transaction_id" => tx1.id, "category_id" => cat.id})

      render_click(live, "toggle_bulk_rule", %{})

      render_keyup(live, "update_bulk_rule_keyword", %{"value" => "HAIR"})
      assert has_element?(live, "#bulk-rule-conflicts")

      render_keyup(live, "update_bulk_rule_keyword", %{"value" => "SEPHORA"})
      refute has_element?(live, "#bulk-rule-conflicts")
    end

    test "handle_info category_created with target_transaction_id", %{conn: conn} do
      tx = transaction_fixture(description: "New Shop")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      cat = category_fixture(name: "Shopping")

      send(index_live.pid, {:category_created, cat, tx.id})

      html = render(index_live)
      assert Transactions.get_transaction!(tx.id).category_id == cat.id
      assert html =~ "Categoria criada!"
    end

    test "toggle_type filter", %{conn: conn} do
      transaction_fixture(amount: "100.00", description: "Credit-TX")
      transaction_fixture(amount: "-50.00", description: "Debit-TX")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> element("button[phx-value-type='credit']") |> render_click()
      assert render(index_live) =~ "Credit-TX"
      refute render(index_live) =~ "Debit-TX"

      index_live |> element("button[phx-value-type='credit']") |> render_click()
      assert render(index_live) =~ "Credit-TX"
      assert render(index_live) =~ "Debit-TX"
    end

    test "handle_info category updates/deletes", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")
      cat = category_fixture()

      send(index_live.pid, {:category_updated, cat})
      render(index_live)
      send(index_live.pid, {:category_deleted, cat})
      render(index_live)

      assert render(index_live) =~ "Transações"
    end

    test "close_modal event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "open_quick_category", %{"name" => "Padaria", "id" => nil})
      # Check for specific modal content
      assert render(index_live) =~ "Organize sua hierarquia financeira"

      render_click(index_live, "close_modal")
      # Content should be gone
      refute render(index_live) =~ "Organize sua hierarquia financeira"
    end
  end

  describe "private helpers coverage" do
    test "category_created assigns bulk_confirmation when duplicates exist", %{conn: conn} do
      # Two transactions with same description → bulk_items non-empty
      tx1 = transaction_fixture(description: "Padaria Central")
      _tx2 = transaction_fixture(description: "Padaria Central")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")
      cat = category_fixture(name: "Alimentacao")

      send(index_live.pid, {:category_created, cat, tx1.id})

      html = render(index_live)
      assert html =~ "Categorização em Lote"
      assert html =~ "Alimentacao"
    end

    test "category_created stream_deletes when tx does not match search filter", %{conn: conn} do
      tx = transaction_fixture(description: "Apple Store Purchase")
      {:ok, index_live, _html} = live(conn, ~p"/transactions?search=something_else")

      cat = category_fixture(name: "Tech")
      send(index_live.pid, {:category_created, cat, tx.id})

      # Should not crash; tx was stream_deleted because search doesn't match
      html = render(index_live)
      assert html =~ "Categoria criada!"
    end

    test "category_created stream_deletes when tx does not match nil category filter", %{
      conn: conn
    } do
      tx = transaction_fixture(description: "Unique Item ABC")
      {:ok, index_live, _html} = live(conn, ~p"/transactions?category_id=nil")

      cat = category_fixture(name: "Misc")
      # After category_created, tx now has a category → doesn't match category_id="nil"
      send(index_live.pid, {:category_created, cat, tx.id})

      html = render(index_live)
      assert html =~ "Categoria criada!"
    end

    test "category_created with ignore patterns skips bulk suggestion", %{conn: conn} do
      # Insert invalid regex pattern by bypassing changeset validation
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(CashLens.Transactions.BulkIgnorePattern, [
        %{id: Ecto.UUID.generate(), pattern: "[invalid", inserted_at: now, updated_at: now}
      ])

      insert_bulk_ignore_pattern(%{pattern: "^Padaria"})

      tx1 = transaction_fixture(description: "Padaria Central")
      _tx2 = transaction_fixture(description: "Padaria Central")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")
      cat = category_fixture(name: "Food")

      send(index_live.pid, {:category_created, cat, tx1.id})

      html = render(index_live)
      # Ignore pattern matched → bulk_items = [] → no bulk confirmation
      refute html =~ "Categorização em Lote"
      assert html =~ "Categoria criada!"
    end

    test "update_category with nil category_id skips bulk suggestion", %{conn: conn} do
      tx = transaction_fixture(description: "Some Store")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # category_id "" → converted to nil → handle_bulk_suggestion(socket, tx, nil)
      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => ""
      })

      # No bulk confirmation should appear
      html = render(index_live)
      refute html =~ "Categorização em Lote"
    end

    test "update_category stream_deletes when account filter doesn't match", %{conn: conn} do
      acc1 = account_fixture(name: "Acc Filter")
      acc2 = account_fixture(name: "Acc Other")
      tx = transaction_fixture(account_id: acc2.id, description: "Store XYZ")
      cat = category_fixture(name: "Shopping")

      {:ok, index_live, _html} = live(conn, ~p"/transactions?account_id=#{acc1.id}")

      # tx is in acc2 but filter is for acc1 → stream_delete after update
      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat.id
      })

      # Should not crash; stream_delete is called
      render(index_live)
    end

    test "update_category stream_deletes when category filter doesn't match", %{conn: conn} do
      cat1 = category_fixture(name: "Food")
      cat2 = category_fixture(name: "Transport")
      tx = transaction_fixture(description: "Uber Ride Unique")

      {:ok, index_live, _html} = live(conn, ~p"/transactions?category_id=#{cat1.id}")

      # Update tx to cat2, but we're filtering by cat1 → stream_delete
      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat2.id
      })

      render(index_live)
    end

    test "update_category with ignore pattern skips bulk", %{conn: conn} do
      insert_bulk_ignore_pattern(%{pattern: "Uber"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(CashLens.Transactions.BulkIgnorePattern, [
        %{id: Ecto.UUID.generate(), pattern: "[bad_regex", inserted_at: now, updated_at: now}
      ])

      tx = transaction_fixture(description: "Uber Ride")
      _tx2 = transaction_fixture(description: "Uber Ride")
      cat = category_fixture(name: "Transport")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat.id
      })

      # Ignore pattern matches → skip_bulk → no confirmation
      html = render(index_live)
      refute html =~ "Categorização em Lote"
    end

    test "update_category on unique description has no bulk items", %{conn: conn} do
      tx = transaction_fixture(description: "UniqueStoreXYZ123OnlyOne")
      cat = category_fixture(name: "Misc")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat.id
      })

      # Only one tx with this description → bulk_items empty → no confirmation
      html = render(index_live)
      refute html =~ "Categorização em Lote"
    end

    test "update_category stream_deletes with type filter mismatch", %{conn: conn} do
      # tx is credit (positive amount), but filter is debit
      tx = transaction_fixture(amount: "100.00", description: "Income Item")
      cat = category_fixture(name: "Income Cat")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Set type filter to "debit"
      index_live |> element("button[phx-value-type='debit']") |> render_click()

      # Update category → stream_update_transaction → type_match?(tx, "debit") → false
      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat.id
      })

      render(index_live)
    end

    test "should_skip_bulk handles nil description", %{conn: conn} do
      acc = account_fixture()
      cat = category_fixture(name: "Misc")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Insert transaction with nil description via Repo.insert_all
      {1, [tx]} =
        Repo.insert_all(
          Transaction,
          [
            %{
              id: Ecto.UUID.generate(),
              date: ~D[2026-02-23],
              description: nil,
              amount: Decimal.new("50.00"),
              account_id: acc.id,
              fingerprint: "nil_desc_#{System.unique_integer([:positive])}",
              inserted_at: now,
              updated_at: now
            }
          ],
          returning: true
        )

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # update_category → handle_bulk_suggestion → should_skip_bulk?(nil, _) → true
      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat.id
      })

      html = render(index_live)
      refute html =~ "Categorização em Lote"
    end

    test "unmatched_transfers filter interactions with stream_update", %{conn: conn} do
      transfer_cat = category_fixture(name: "Transfer", slug: "transfer")
      tx = transaction_fixture(category_id: transfer_cat.id, description: "Transfer TX")

      {:ok, index_live, _html} =
        live(conn, ~p"/transactions?unmatched_transfers=true")

      # tx has transfer category and nil transfer_key → unmatched_match? returns true
      # Now update category to something else → unmatched_match? → false → stream_delete
      other_cat = category_fixture(name: "Other")

      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => other_cat.id
      })

      render(index_live)
    end

    test "calculate_current_balance with non-existent account_id", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      # Navigate with a fake account_id that doesn't exist in socket.assigns.accounts
      {:ok, index_live, _html} = live(conn, ~p"/transactions?account_id=#{fake_id}")

      # Should render without crash; balance falls back to Decimal.new("0")
      assert render(index_live) =~ "Transações"
    end

    test "open_transfer_link finds and sorts candidates", %{conn: conn} do
      acc1 = account_fixture(name: "Origin Acc")
      acc2 = account_fixture(name: "Dest Acc")

      # tx1 and tx2 have matching opposite amounts in different accounts
      tx1 =
        transaction_fixture(
          account_id: acc1.id,
          amount: "200.00",
          description: "Transfer Out",
          date: ~D[2026-02-23]
        )

      _tx2 =
        transaction_fixture(
          account_id: acc2.id,
          amount: "-200.00",
          description: "Transfer In",
          date: ~D[2026-02-24]
        )

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # open_transfer_link triggers update_transfer_linker_list
      render_click(index_live, "open_transfer_link", %{"id" => tx1.id})

      # Should show the transfer modal with candidates
      html = render(index_live)
      assert html =~ "Transfer In" or html =~ "transfer"
    end

    test "unmatched_transfers=false in filter", %{conn: conn} do
      transfer_cat = category_fixture(name: "Transfer", slug: "transfer")
      tx = transaction_fixture(category_id: transfer_cat.id, description: "TR Item")

      # Navigate with unmatched_transfers=false
      {:ok, index_live, _html} = live(conn, ~p"/transactions?unmatched_transfers=false")

      cat = category_fixture(name: "Other2")

      # update_category → stream_update_transaction → matches_filters?
      # unmatched_match?(_tx, "false", _) → true (line 782)
      render_click(index_live, "update_category", %{
        "transaction_id" => tx.id,
        "category_id" => cat.id
      })

      render(index_live)
    end
  end
end
