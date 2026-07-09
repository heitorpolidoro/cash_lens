defmodule CashLensWeb.TransactionLive.BatchImportModalComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures

  alias CashLens.Parsers.DirectoryImporter

  test "cycle divergence warning renders and update_cycle persists the file's due_day", %{
    conn: conn
  } do
    account =
      account_fixture(is_credit_card: true, closing_day: 10, due_day: 17)

    result = %DirectoryImporter.Result{
      accounts: [],
      cycle_warnings: [
        %{
          account_id: account.id,
          account_name: account.name,
          file: "extrato.csv",
          file_due_day: 20,
          configured_due_day: 17
        }
      ]
    }

    {:ok, index_live, _html} = live(conn, ~p"/transactions")

    index_live |> render_click("open_batch_import")

    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{phase: :done, result: result}
    )

    html = render(index_live)
    assert html =~ account.name
    assert html =~ "Atualizar"
    assert html =~ "dia 20"
    assert html =~ "dia 17"

    index_live
    |> element("button[phx-click='update_cycle'][phx-value-account-id='#{account.id}']")
    |> render_click()

    updated_account = CashLens.Repo.get!(CashLens.Accounts.Account, account.id)
    assert updated_account.due_day == 20

    # The warning is dropped from the rendered list after the update.
    refute render(index_live) =~ "Atualizar"
  end
end
