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

  test "a completed preview shows per-account counts and offers confirm/cancel", %{conn: conn} do
    account = account_fixture(bank: "Banco Teste", name: "Conta Teste")

    result = %DirectoryImporter.Result{
      accounts: [
        %{
          account: account,
          bank: account.bank,
          name: account.name,
          folder_path: "conta-teste",
          imported: 3,
          skipped: 1,
          failed: []
        }
      ]
    }

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{phase: :preview_confirm, result: result}
    )

    html = render(index_live)
    assert html =~ "conta-teste"
    assert html =~ "3 novas"
    assert html =~ "1 já existem"
    assert html =~ "Confirmar Importação"
    assert html =~ "Cancelar"
  end

  test "cancelling a preview returns to the idle path form with no writes", %{conn: conn} do
    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{phase: :preview_confirm, result: %DirectoryImporter.Result{}}
    )

    html =
      index_live
      |> element("button[phx-click='cancel_confirmation']")
      |> render_click()

    assert html =~ "Caminho da Pasta"
    refute html =~ "Confirmar Importação"
  end

  test "submitting a path with all accounts already present previews before importing", %{
    conn: conn
  } do
    account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

    root = Path.join(System.tmp_dir!(), "batchpreview_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, ".account"), "bank: Banco do Brasil\naccount: Conta Corrente\n")

    File.write!(
      Path.join(root, "extrato.csv"),
      File.read!("test/support/fixtures/files/bb_sample.csv")
    )

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    index_live
    |> form("#batch-import-form", %{"path" => root})
    |> render_submit()

    # The load-bearing assertion: submitting alone must never write, whether
    # the render caught the brief ":previewing" progress state or already
    # settled on ":preview_confirm" by the time this returns (both are valid
    # — `:sql_sandbox` mode runs the dry-run inline, so exactly which of the
    # two the returned HTML reflects is a timing detail, not the behavior
    # under test). `render/1` after a moment lets any queued
    # `:batch_import_finished` message be processed, then checks the
    # settled screen.
    html = render(index_live)
    assert html =~ "novas" or html =~ "Calculando Pré-visualização..."
    assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 0
  end
end
