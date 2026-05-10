defmodule CashLensWeb.TransactionLive.ImportModalComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures

  test "summarize_import_results error branch", %{conn: conn} do
    # Use an account without a configured parser to trigger an error
    account = account_fixture(accepts_import: true, parser_type: "unknown")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")

    index_live |> render_click("open_import")

    # Select account
    index_live
    |> element("#upload-form")
    |> render_change(%{"account_id" => account.id})

    # Upload one file - use .csv to avoid PDF converter Mox issues
    csv_content = "date,description,amount\n2024-01-01,test,100.00"

    file1 = %{
      last_modified: 1_594_171_879_000,
      name: "valid.csv",
      content: csv_content,
      size: byte_size(csv_content),
      type: "text/csv"
    }

    input = file_input(index_live, "#upload-form", :statement, [file1])
    render_upload(input, "valid.csv")

    index_live |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    # The error is sent to parent which puts it in flash
    assert render(index_live) =~ "1 files failed"
    assert render(index_live) =~ "Total transactions from successful files: 0"
  end

  test "cancel-upload event", %{conn: conn} do
    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_import")

    file = %{
      last_modified: 1_594_171_879_000,
      name: "test.csv",
      content: "test",
      size: 4,
      type: "text/csv"
    }

    input = file_input(index_live, "#upload-form", :statement, [file])
    # Use render_upload to populate the entries correctly
    render_upload(input, "test.csv")

    html = render(index_live)
    assert html =~ "test.csv"

    # Get the ref
    [_, ref] = Regex.run(~r/phx-value-ref="([^"]+)"/, html)

    index_live
    |> element("button[phx-click='cancel-upload'][phx-value-ref='#{ref}']")
    |> render_click()

    refute render(index_live) =~ "test.csv"
  end
end
