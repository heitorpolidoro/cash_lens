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

  test "a batch_import_finished-derived progress_update with a stale run_token is ignored", %{
    conn: conn
  } do
    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    # No run has been started in this component instance, so its current
    # run_token is still the initial 0. A progress_update carrying some other
    # token simulates a result from an earlier/different run arriving late
    # (e.g. after the modal was closed and reopened, or a duplicate in-flight
    # run) — it must not resurrect a confirm screen the current state never
    # asked for.
    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{
        phase: :preview_confirm,
        result: %DirectoryImporter.Result{},
        run_token: 999
      }
    )

    html = render(index_live)
    refute html =~ "Confirmar Importação"
    assert html =~ "Caminho da Pasta"
  end

  test "closing the modal mid-run invalidates that run's token so its late result is dropped", %{
    conn: conn
  } do
    account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

    root = Path.join(System.tmp_dir!(), "batchclose_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, ".account"), "bank: Banco do Brasil\naccount: Conta Corrente\n")

    File.write!(
      Path.join(root, "extrato.csv"),
      File.read!("test/support/fixtures/files/bb_sample.csv")
    )

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    # Starting the run bumps the component's run_token from 0 to 1 (see
    # `next_run_token/1` in the `:ok` preflight branch of
    # "start_batch_import"). In :sql_sandbox test mode the dry-run itself
    # executes inline and may or may not have settled into :preview_confirm
    # by the time this returns — either way, the token minted for this run
    # is 1.
    index_live
    |> form("#batch-import-form", %{"path" => root})
    |> render_submit()

    # Close the modal while this run is (or may still be) in flight — the
    # exact scenario `idle_progress/1` exists to guard: the user walks away
    # before the dry-run result comes back.
    index_live
    |> element("button[aria-label='close']")
    |> render_click()

    # Simulate that abandoned run's result arriving late, exactly as
    # `index.ex`'s `handle_info({:batch_import_finished, ...})` would relay
    # it — tagged with the SAME token (1) that was current when the run
    # started and the modal was closed.
    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{
        phase: :preview_confirm,
        result: %DirectoryImporter.Result{},
        run_token: 1
      }
    )

    # Reopen the modal: it must show the idle path-form state, not a stale
    # confirm screen resurrected by the late-arriving message.
    index_live |> render_click("open_batch_import")
    html = render(index_live)

    refute html =~ "Confirmar Importação"
    assert html =~ "Caminho da Pasta"
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
