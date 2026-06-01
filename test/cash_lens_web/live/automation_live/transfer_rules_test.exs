defmodule CashLensWeb.AutomationLive.TransferRulesTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Transactions

  setup do
    source = account_fixture(%{name: "Source Account"})
    destination = account_fixture(%{name: "Destination Account"})
    %{source: source, destination: destination}
  end

  test "mounts and renders empty state", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin/transfer_rules")
    assert html =~ "Regras de Transferência"
  end

  test "renders existing rule in table", %{conn: conn, source: source, destination: destination} do
    _rule =
      transfer_rule_fixture(%{
        label: "My Test Rule",
        description_patterns: ["test pattern"],
        source_account_id: source.id,
        destination_account_id: destination.id
      })

    {:ok, _live, html} = live(conn, ~p"/admin/transfer_rules")
    assert html =~ "My Test Rule"
    assert html =~ "test pattern"
  end

  test "creates a new transfer rule via form", %{
    conn: conn,
    source: source,
    destination: destination
  } do
    {:ok, live, _html} = live(conn, ~p"/admin/transfer_rules")

    html =
      live
      |> form("#transfer-rule-form", %{
        "transfer_rule" => %{
          "label" => "New Rule",
          "description_patterns_raw" => "Pattern A, Pattern B",
          "source_account_id" => source.id,
          "destination_account_id" => destination.id
        }
      })
      |> render_submit()

    assert html =~ "Regra de transferência salva!"
    assert html =~ "New Rule"
    assert html =~ "Pattern A"
  end

  test "validate event updates form without saving", %{
    conn: conn,
    source: source,
    destination: destination
  } do
    {:ok, live, _html} = live(conn, ~p"/admin/transfer_rules")

    html =
      live
      |> form("#transfer-rule-form", %{
        "transfer_rule" => %{
          "label" => "Draft",
          "description_patterns_raw" => "pattern",
          "source_account_id" => source.id,
          "destination_account_id" => destination.id
        }
      })
      |> render_change()

    assert html =~ "Draft"
    assert Transactions.list_transfer_rules() == []
  end

  test "shows validation error for missing required fields", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/admin/transfer_rules")

    html =
      live
      |> form("#transfer-rule-form", %{
        "transfer_rule" => %{
          "description_patterns_raw" => "",
          "source_account_id" => "",
          "destination_account_id" => ""
        }
      })
      |> render_submit()

    assert html =~ "can&#39;t be blank"
  end

  test "edits an existing rule", %{conn: conn, source: source, destination: destination} do
    rule =
      transfer_rule_fixture(%{
        label: "Original Label",
        description_patterns: ["original pattern"],
        source_account_id: source.id,
        destination_account_id: destination.id
      })

    {:ok, live, _html} = live(conn, ~p"/admin/transfer_rules")

    live
    |> element("button[phx-click='edit'][phx-value-id='#{rule.id}']")
    |> render_click()

    html =
      live
      |> form("#transfer-rule-form", %{
        "transfer_rule" => %{
          "label" => "Updated Label",
          "description_patterns_raw" => "updated pattern",
          "source_account_id" => source.id,
          "destination_account_id" => destination.id
        }
      })
      |> render_submit()

    assert html =~ "Regra de transferência salva!"
    assert html =~ "Updated Label"
    assert html =~ "updated pattern"

    updated = Transactions.get_transfer_rule!(rule.id)
    assert updated.label == "Updated Label"
    assert updated.description_patterns == ["updated pattern"]
  end

  test "cancel edit returns form to new state", %{
    conn: conn,
    source: source,
    destination: destination
  } do
    rule =
      transfer_rule_fixture(%{
        label: "Rule to Cancel",
        description_patterns: ["cancel me"],
        source_account_id: source.id,
        destination_account_id: destination.id
      })

    {:ok, live, _html} = live(conn, ~p"/admin/transfer_rules")

    live
    |> element("button[phx-click='edit'][phx-value-id='#{rule.id}']")
    |> render_click()

    html =
      live
      |> element("button[phx-click='cancel_edit']")
      |> render_click()

    # After cancel, no Cancel button should be present (form is in "new" state)
    refute html =~ "phx-click=\"cancel_edit\""
  end

  test "deletes a rule", %{conn: conn, source: source, destination: destination} do
    rule =
      transfer_rule_fixture(%{
        label: "Delete Me",
        description_patterns: ["delete pattern"],
        source_account_id: source.id,
        destination_account_id: destination.id
      })

    {:ok, live, _html} = live(conn, ~p"/admin/transfer_rules")

    assert render(live) =~ "Delete Me"

    html =
      live
      |> element("button[phx-click='delete'][phx-value-id='#{rule.id}']")
      |> render_click()

    assert html =~ "Regra de transferência excluída."
    refute render(live) =~ "Delete Me"
  end
end
