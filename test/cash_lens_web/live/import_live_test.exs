defmodule CashLensWeb.ImportLiveTest do
  @moduledoc """
  Covers the `/imports` shell: the monitored-folder card, the colour-coded file
  list and the error/empty states.

  `CashLens.Settings` writes a real `priv/settings.json` shared with the
  developer's environment, so the `setup` below captures the monitored-root
  key and restores it verbatim on exit. A test run must leave that key
  byte-identical to what it was before.
  """
  use CashLensWeb.ConnCase, async: false

  import CashLens.AccountsFixtures
  import Phoenix.LiveViewTest

  import Ecto.Query, only: [from: 2]

  alias CashLens.Imports
  alias CashLens.Settings

  @root_setting "last_batch_import_path"

  @bb_sample File.read!("test/support/fixtures/files/bb_sample.csv")

  @other_sample """
  Data,Dependência Origem,Term. Origem,Histórico,Documento,Valor,
  20/02/2026,0000,0000,SALDO ANTERIOR,,0.00,
  24/02/2026,1234,5678,OUTRA COISA,123.456,-99.00,
  """

  setup do
    previous_root = Settings.get(@root_setting, "")
    on_exit(fn -> Settings.put(@root_setting, previous_root) end)

    root = Path.join(System.tmp_dir!(), "import_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    account =
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

    Settings.put(@root_setting, root)

    {:ok, root: root, account: account}
  end

  defp account_folder(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".account"),
      "bank: Banco do Brasil\naccount: Conta Corrente\nparser: bb_csv\n"
    )

    dir
  end

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp record_import(path_key, file) do
    Imports.upsert_imported_file(%{
      path: path_key,
      content_hash: Imports.content_hash(File.read!(file)),
      mtime: Imports.file_mtime(file),
      last_imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp other_dir do
    dir = Path.join(System.tmp_dir!(), "import_live_other_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "mount" do
    test "renders the configured monitored root", %{conn: conn, root: root} do
      {:ok, _view, html} = live(conn, ~p"/imports")

      assert html =~ "Central de Importação"
      assert html =~ root
    end

    test "falls back to the default root when the setting is unset", %{conn: conn} do
      Settings.put(@root_setting, "")

      {:ok, _view, html} = live(conn, ~p"/imports")

      assert html =~ Imports.default_import_root()
      # The default is displayed, never silently persisted.
      assert Imports.import_root([]) == nil
    end

    test "renders the empty state for a valid but empty root", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/imports")

      assert html =~ ~s(id="scan-empty")
      assert html =~ "Nenhum arquivo encontrado"
      refute html =~ ~s(id="file-list")
    end
  end

  describe "saving the monitored folder" do
    test "persists a valid directory and lists its files", %{conn: conn} do
      new_root = other_dir()
      dir = account_folder(new_root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      html =
        view
        |> form("#import-root-form", %{"path" => new_root})
        |> render_submit()

      assert Imports.import_root([]) == new_root
      assert html =~ "bb/extrato.csv"
      assert html =~ ~s(data-path="bb/extrato.csv")
    end

    test "rejects a blank path without persisting it", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/imports")

      html =
        view
        |> form("#import-root-form", %{"path" => "   "})
        |> render_submit()

      assert Imports.import_root([]) == root
      assert html =~ "Informe um caminho."
    end

    test "persists an existing path that is not a directory and shows the error state", %{
      conn: conn
    } do
      file = Path.join(other_dir(), "not-a-folder.csv")
      File.write!(file, @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      html =
        view
        |> form("#import-root-form", %{"path" => file})
        |> render_submit()

      assert Imports.import_root([]) == file
      assert html =~ ~s(id="scan-error")
      assert html =~ "Pasta não encontrada"
      assert html =~ "Caminho salvo, mas a pasta não foi encontrada."
    end
  end

  describe "status classification" do
    test "renders a never-imported file as new", %{conn: conn, root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      assert has_element?(view, ~s(tr[data-path="bb/extrato.csv"][data-status="new"]))
      assert render(view) =~ "Novo"
    end

    test "renders an unchanged imported file as synced", %{conn: conn, root: root} do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)
      record_import("bb/extrato.csv", file)

      {:ok, view, _html} = live(conn, ~p"/imports")

      assert has_element?(view, ~s(tr[data-path="bb/extrato.csv"][data-status="synced"]))
      assert render(view) =~ "Sincronizado"
    end

    test "renders a rewritten file as updated, with the new disk hash", %{conn: conn, root: root} do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)
      record_import("bb/extrato.csv", file)

      File.write!(file, @other_sample)
      new_hash = Imports.content_hash(File.read!(file))

      {:ok, view, _html} = live(conn, ~p"/imports")
      html = render(view)

      assert has_element?(view, ~s(tr[data-path="bb/extrato.csv"][data-status="updated"]))
      assert html =~ "Atualizado"
      assert html =~ String.slice(new_hash, 0, 8)
      assert html =~ "modificado em"
      assert html =~ "importado em"
    end
  end

  describe "rescan" do
    test "picks up a file created after mount", %{conn: conn, root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")
      refute has_element?(view, ~s(tr[data-path="bb/extrato2.csv"]))

      write_file(dir, "extrato2.csv", @other_sample)

      html = view |> element("#rescan-button") |> render_click()

      assert has_element?(view, ~s(tr[data-path="bb/extrato2.csv"]))
      assert html =~ "Pasta reescaneada."
    end
  end

  describe "missing root" do
    test "renders the scan error state without crashing", %{conn: conn} do
      missing = Path.join(System.tmp_dir!(), "missing_#{System.unique_integer([:positive])}")
      Settings.put(@root_setting, missing)

      {:ok, _view, html} = live(conn, ~p"/imports")

      assert html =~ ~s(id="scan-error")
      assert html =~ "Pasta não encontrada"
      assert html =~ missing
    end
  end

  describe "pre-write inspection" do
    alias CashLens.CreditCards.Statement
    alias CashLens.Imports.ImportedFile
    alias CashLens.Imports.ImportRun
    alias CashLens.Parsers.Ingestor
    alias CashLens.Repo
    alias CashLens.Transactions.Transaction

    defp counts do
      %{
        transactions: Repo.aggregate(Transaction, :count),
        imported_files: Repo.aggregate(ImportedFile, :count),
        import_runs: Repo.aggregate(ImportRun, :count),
        statements: Repo.aggregate(Statement, :count)
      }
    end

    test "opening the drawer shows the dry run's new count", %{
      conn: conn,
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)

      {:ok, %{imported: expected}} = Ingestor.import_file(account, file, dry_run: true)

      {:ok, view, _html} = live(conn, ~p"/imports")

      html =
        view
        |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
        |> render_click()

      assert html =~ ~s(id="inspect-drawer")
      assert html =~ "bb/extrato.csv"

      assert view |> element("#preview-new-count") |> render() =~ to_string(expected)
      assert view |> element("#preview-skipped-count") |> render() =~ "0"
      assert length(preview_rows(view)) == expected
    end

    test "opening and closing the drawer writes nothing", %{conn: conn, root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      before = counts()

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      assert has_element?(view, "#inspect-drawer")
      assert counts() == before

      view |> element("#inspect-cancel") |> render_click()

      refute has_element?(view, "#inspect-drawer")
      assert counts() == before
    end

    test "confirming runs the real import", %{conn: conn, root: root, account: account} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      expected = view |> element("#preview-new-count") |> render() |> extract_count()

      html = view |> element("#confirm-import") |> render_click()

      assert Repo.aggregate(
               from(t in Transaction, where: t.account_id == ^account.id),
               :count
             ) == expected

      assert [run] = Repo.all(ImportRun)
      assert run.imported_count == expected
      assert Imports.get_imported_file_by_path("bb/extrato.csv")

      refute html =~ ~s(id="inspect-drawer")
      assert has_element?(view, ~s(tr[data-path="bb/extrato.csv"][data-status="synced"]))
      assert html =~ "#{expected} transações importadas"
    end

    test "inspecting an already-imported file previews only duplicates", %{
      conn: conn,
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)

      {:ok, _} = Ingestor.import_file(account, file, import_root: root)
      before = Repo.aggregate(Transaction, :count)

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      assert view |> element("#preview-new-count") |> render() |> extract_count() == 0
      assert preview_rows(view) != []
      assert Enum.all?(preview_rows(view), &(&1 == "duplicate"))

      view |> element("#confirm-import") |> render_click()

      assert Repo.aggregate(Transaction, :count) == before
    end

    test "a file rewritten after the drawer opened refuses the confirm", %{
      conn: conn,
      root: root
    } do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      File.write!(file, @other_sample)

      html = view |> element("#confirm-import") |> render_click()

      assert html =~ "O arquivo mudou no disco."
      assert Repo.aggregate(Transaction, :count) == 0
      assert Repo.aggregate(ImportRun, :count) == 0
      assert has_element?(view, "#inspect-drawer")
    end

    test "a file whose account does not exist opens on the error block", %{
      conn: conn,
      root: root
    } do
      dir = Path.join(root, "unknown")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".account"),
        "bank: Banco Fantasma\naccount: Conta Fantasma\nparser: bb_csv\n"
      )

      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="unknown/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      assert has_element?(view, "#inspect-error")
      refute has_element?(view, "#confirm-import")
    end

    test "a preview longer than the limit renders 200 rows and the full counters", %{
      conn: conn,
      root: root
    } do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", big_sample(205))

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      assert length(preview_rows(view)) == 200
      assert view |> element("#preview-new-count") |> render() |> extract_count() == 205
      assert view |> element("#preview-truncated") |> render() =~ "mostrando 200 de 205 linhas"
    end

    defp preview_rows(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-preview-row]")
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-row-status") |> List.first()))
    end

    defp extract_count(html) do
      html |> String.replace(~r/<[^>]*>/, "") |> String.trim() |> String.to_integer()
    end

    defp big_sample(rows) do
      header = "Data,Dependência Origem,Term. Origem,Histórico,Documento,Valor,\n"

      body =
        Enum.map_join(1..rows, "", fn i ->
          "10/03/2026,1234,5678,COMPRA TESTE #{i},123.#{i},-1.00,\n"
        end)

      header <> body
    end
  end

  describe "recent import history" do
    alias CashLens.Imports.ImportRun
    alias CashLens.Parsers.Ingestor
    alias CashLens.Repo
    alias CashLens.Transactions.Transaction

    @hash "9f2c4b7e1d8a0356e4b1c9d72f0a68b35c1e7d40a9b2f83c6d5e0147a8b93c2f"

    defp run_fixture(attrs) do
      {:ok, run} =
        Imports.record_run(
          Enum.into(attrs, %{
            ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
            file_path: "bb/extrato.csv",
            status: "success"
          })
        )

      run
    end

    defp history_rows(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#import-history tbody tr")
    end

    defp row_cells(view, run_id) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(#import-history tbody tr[data-run-id="#{run_id}"] td))
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    test "renders one row per run with every column read from import_runs", %{
      conn: conn,
      account: account
    } do
      run =
        run_fixture(
          ran_at: ~U[2026-09-20 14:32:00Z],
          account_id: account.id,
          file_path: "bb-corrente/extrato-2026-09.csv",
          imported_count: 7,
          skipped_count: 3
        )

      {:ok, view, html} = live(conn, ~p"/imports")

      assert html =~ ~s(id="import-history")
      assert html =~ "Importações recentes"
      assert html =~ "Últimas 20 execuções"
      assert has_element?(view, ~s(tr[data-run-id="#{run.id}"][data-run-status="success"]))

      cells = row_cells(view, run.id)

      assert Enum.at(cells, 0) =~ "20/09/2026 14:32"
      assert Enum.at(cells, 1) =~ "Banco do Brasil - Conta Corrente"
      assert Enum.at(cells, 2) =~ "extrato-2026-09.csv"
      assert Enum.at(cells, 3) =~ "Sucesso"
      assert Enum.at(cells, 4) == "7"
      assert Enum.at(cells, 5) == "3"
    end

    test "renders one badge per stored status", %{conn: conn, account: account} do
      success = run_fixture(account_id: account.id, status: "success")
      warning = run_fixture(account_id: account.id, status: "warning", failed_count: 3)
      error = run_fixture(account_id: account.id, status: "error")

      {:ok, view, _html} = live(conn, ~p"/imports")

      assert view
             |> element(~s(tr[data-run-id="#{success.id}"][data-run-status="success"]))
             |> render() =~ "Sucesso"

      assert view
             |> element(~s(tr[data-run-id="#{warning.id}"][data-run-status="warning"]))
             |> render() =~ "Aviso"

      assert view
             |> element(~s(tr[data-run-id="#{error.id}"][data-run-status="error"]))
             |> render() =~ "Erro"

      assert view
             |> element(~s(tr[data-run-id="#{warning.id}"] [data-role="run-failed"]))
             |> render() =~ "3 linha(s) rejeitada(s)"
    end

    test "renders an unknown status as a grey badge with the raw value", %{
      conn: conn,
      account: account
    } do
      # Written around the changeset on purpose: the badge must be total over
      # any string the column can physically hold.
      {:ok, run} =
        Repo.insert(%ImportRun{
          ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
          account_id: account.id,
          file_path: "bb/extrato.csv",
          status: "partial"
        })

      {:ok, view, _html} = live(conn, ~p"/imports")

      row =
        view |> element(~s(tr[data-run-id="#{run.id}"][data-run-status="partial"])) |> render()

      assert row =~ "partial"
      assert row =~ "bg-slate-100"
    end

    test "renders the newest 20 runs, newest first, with no pagination control", %{
      conn: conn,
      account: account
    } do
      runs =
        for offset <- 0..24 do
          run_fixture(
            account_id: account.id,
            ran_at: DateTime.add(~U[2026-09-20 14:00:00Z], -offset * 3600, :second),
            file_path: "bb/extrato-#{offset}.csv"
          )
        end

      {:ok, view, html} = live(conn, ~p"/imports")

      rows = history_rows(view)
      assert Enum.count(rows) == 20

      ids = Enum.map(rows, &(&1 |> LazyHTML.attribute("data-run-id") |> List.first()))

      assert ids == runs |> Enum.take(20) |> Enum.map(& &1.id)

      refute html =~ "Ver mais"
      refute html =~ ~s(id="history-pagination")
    end

    test "lists an error run with its message and zeroed counts", %{
      conn: conn,
      account: account
    } do
      run =
        run_fixture(
          account_id: account.id,
          status: "error",
          error_message: "Could not read file: enoent"
        )

      {:ok, view, _html} = live(conn, ~p"/imports")

      cells = row_cells(view, run.id)

      assert Enum.at(cells, 3) =~ "Erro"
      assert Enum.at(cells, 4) == "0"
      assert Enum.at(cells, 5) == "0"

      assert view
             |> element(~s(tr[data-run-id="#{run.id}"] [data-role="run-error"]))
             |> render() =~ "Could not read file: enoent"
    end

    test "renders an em dash for a run whose account is nil", %{conn: conn} do
      run = run_fixture(account_id: nil)

      {:ok, view, _html} = live(conn, ~p"/imports")

      assert run.account_id == nil
      assert view |> row_cells(run.id) |> Enum.at(1) == "—"
    end

    test "renders a content-hash path as its basename plus a loose-file marker", %{
      conn: conn,
      account: account
    } do
      run = run_fixture(account_id: account.id, file_path: "#{@hash}/nubank.csv")

      {:ok, view, _html} = live(conn, ~p"/imports")

      file_cell = view |> row_cells(run.id) |> Enum.at(2)

      assert file_cell =~ "nubank.csv"
      assert file_cell =~ "Arquivo solto"
      assert file_cell =~ String.slice(@hash, 0, 8)
      refute file_cell =~ @hash
    end

    test "renders the empty state with no runs at all", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/imports")

      assert html =~ ~s(id="import-history")
      assert html =~ ~s(id="history-empty")
      assert html =~ "Nenhuma importação registrada ainda."
      assert history_rows(view) |> Enum.count() == 0
    end

    test "shows the new run after an import confirmed on the screen", %{
      conn: conn,
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      assert has_element?(view, "#history-empty")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      view |> element("#confirm-import") |> render_click()

      imported =
        Repo.aggregate(from(t in Transaction, where: t.account_id == ^account.id), :count)

      assert [run] = Repo.all(ImportRun)
      assert [row] = Enum.to_list(history_rows(view))
      assert row |> LazyHTML.attribute("data-run-id") |> List.first() == run.id
      refute has_element?(view, "#history-empty")
      assert view |> row_cells(run.id) |> Enum.at(4) == to_string(imported)
    end

    test "refreshes the panel on rescan", %{conn: conn, root: root, account: account} do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")
      assert has_element?(view, "#history-empty")

      {:ok, _summary} = Ingestor.import_file(account, file, import_root: root)

      view |> element("#rescan-button") |> render_click()

      assert [run] = Repo.all(ImportRun)
      assert has_element?(view, ~s(tr[data-run-id="#{run.id}"]))
    end
  end

  describe "universal dropzone" do
    alias CashLens.Imports.ImportedFile
    alias CashLens.Imports.ImportRun
    alias CashLens.Parsers.PDFConverterMock
    alias CashLens.Repo
    alias CashLens.Transactions.Transaction

    # Body of test/cash_lens/parsers/ofx_parser_test.exs:5.
    @ofx_sample """
    <OFX>
    <STMTTRN>
    <TRNTYPE>DEBIT</TRNTYPE>
    <DTPOSTED>20260410120000</DTPOSTED>
    <TRNAMT>-150.00</TRNAMT>
    <MEMO>COMPRA SUPERMERCADO</MEMO>
    </STMTTRN>
    <STMTTRN>
    <TRNTYPE>CREDIT</TRNTYPE>
    <DTPOSTED>20260415103000</DTPOSTED>
    <TRNAMT>1200,50</TRNAMT>
    <NAME>TRANSFERENCIA RECEBIDA</NAME>
    </STMTTRN>
    </OFX>
    """

    # Body of test/cash_lens/parsers/ourocard_txt_parser_test.exs:5.
    @ourocard_sample """
                             Fatura do Cartão de Crédito
    Vencimento      : 16.07.2026
    Total da fatura : R$ 11.938,58

    Data     Transações                             País        Valor R$   Valor US$
    --------------------------------------------------------------------------------
             1 - HEITOR L POLIDORO

             Educação
    15.06.2026SCHOOL OF ROCK         SAO JOSE DOS  BR              537,82        0,00
    """

    # Text lifted from test/cash_lens/parsers/pdf_parser_test.exs:8.
    @sem_parar_text """
    Extrato Mensal de Utilização
    Plano Contratado: SEM PARAR 10/12/25 R$ 58,17
    01/12/2025 PEDAGIO SP R$ 10,00
    """

    @raw_pdf "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n"

    @garbage <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46>>

    setup do
      before = session_names()
      on_exit(fn -> Enum.each(new_sessions(before), &File.rm_rf!/1) end)
      {:ok, sessions_before: before}
    end

    defp session_names do
      case File.ls(Imports.drop_root()) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end
    end

    defp new_sessions(before) do
      (session_names() -- before) |> Enum.map(&Path.join(Imports.drop_root(), &1))
    end

    # Every staging directory this test created, across the sessions it created.
    defp staged_dirs(before) do
      before
      |> new_sessions()
      |> Enum.flat_map(fn session ->
        case File.ls(session) do
          {:ok, names} -> Enum.map(names, &Path.join(session, &1))
          {:error, _reason} -> []
        end
      end)
    end

    defp drop_file(view, name, content) do
      view
      |> file_input("#dropzone-form", :drop, [
        %{name: name, content: content, type: "application/octet-stream"}
      ])
      |> render_upload(name)

      render(view)
    end

    defp detection(view), do: view |> element("#drop-detection") |> render()

    defp account_options(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#drop-account option")
      |> Enum.map(&LazyHTML.text/1)
    end

    defp select_account(view, account) do
      view
      |> form("#drop-account-form", %{"account_id" => to_string(account.id)})
      |> render_change()
    end

    test "the dropzone is rendered with a file input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/imports")

      assert html =~ ~s(id="dropzone")
      assert html =~ "Arraste um extrato aqui (OFX, CSV, PDF ou TXT) ou clique para escolher"
      assert html =~ "phx-drop-target"
    end

    test "a dropped CSV is detected and previewed for its only candidate", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/imports")

      html = drop_file(view, "bb_sample.csv", @bb_sample)

      assert html =~ ~s(id="inspect-drawer")
      assert html =~ "bb_sample.csv"
      assert detection(view) =~ "CSV"
      assert detection(view) =~ "bb_csv"
      assert view |> element("#preview-new-count") |> render() |> extract_count() > 0
    end

    test "a dropped OFX is detected and previewed", %{conn: conn} do
      account_fixture(bank: "Itaú", name: "Conta OFX", parser_type: "standard_ofx")

      {:ok, view, _html} = live(conn, ~p"/imports")

      html = drop_file(view, "extrato.ofx", @ofx_sample)

      assert html =~ ~s(id="inspect-drawer")
      assert detection(view) =~ "OFX"
      assert detection(view) =~ "standard_ofx"
      assert view |> element("#preview-new-count") |> render() |> extract_count() == 2
    end

    test "a dropped Ourocard TXT is detected and previewed", %{conn: conn} do
      account_fixture(bank: "Banco do Brasil", name: "Ourocard", parser_type: "ourocard_txt")

      {:ok, view, _html} = live(conn, ~p"/imports")

      html = drop_file(view, "ourocard.txt", @ourocard_sample)

      assert html =~ ~s(id="inspect-drawer")
      assert detection(view) =~ "TXT"
      assert detection(view) =~ "ourocard_txt"
      assert view |> element("#preview-new-count") |> render() |> extract_count() == 1
    end

    test "a dropped PDF is detected through the extracted text", %{conn: conn} do
      account_fixture(bank: "Sem Parar", name: "Tag", parser_type: "sem_parar_pdf")

      {:ok, view, _html} = live(conn, ~p"/imports")

      Mox.stub(PDFConverterMock, :convert, fn _path -> {:ok, @sem_parar_text} end)
      Mox.allow(PDFConverterMock, self(), view.pid)

      html = drop_file(view, "fatura.pdf", @raw_pdf)

      assert html =~ ~s(id="inspect-drawer")
      assert detection(view) =~ "PDF"
      assert detection(view) =~ "sem_parar_pdf"
    end

    test "unrecognised content writes nothing and leaves no staged file", %{
      conn: conn,
      sessions_before: before
    } do
      {:ok, view, _html} = live(conn, ~p"/imports")

      counts_before = counts()

      html = drop_file(view, "lixo.csv", @garbage)

      assert html =~ ~s(id="drop-error")
      assert html =~ "Formato não reconhecido: lixo.csv"
      refute html =~ ~s(id="inspect-drawer")
      assert counts() == counts_before
      assert staged_dirs(before) == []

      html = view |> element("#drop-error-dismiss") |> render_click()
      refute html =~ ~s(id="drop-error")
    end

    test "content decides the format, not the extension", %{conn: conn} do
      ofx = account_fixture(bank: "Itaú", name: "Conta OFX", parser_type: "standard_ofx")

      {:ok, view, _html} = live(conn, ~p"/imports")

      drop_file(view, "extrato.csv", @ofx_sample)

      assert detection(view) =~ "OFX"
      assert Enum.any?(account_options(view), &(&1 =~ ofx.name))
      refute Enum.any?(account_options(view), &(&1 =~ "bb_csv"))
    end

    test "an ourocard_ofx account is a candidate for an OFX drop", %{conn: conn} do
      ourocard = account_fixture(bank: "Itaú", name: "Cartão OFX", parser_type: "ourocard_ofx")

      {:ok, view, _html} = live(conn, ~p"/imports")

      html = drop_file(view, "extrato.ofx", @ofx_sample)

      assert Enum.any?(account_options(view), &(&1 =~ ourocard.name))
      refute html =~ "Nenhuma conta compatível com este formato."

      # The predicate is the extension family, not "everything": a CSV drop
      # never offers the OFX account.
      drop_file(view, "bb_sample.csv", @bb_sample)

      refute Enum.any?(account_options(view), &(&1 =~ ourocard.name))
    end

    test "nothing is written while the drawer is open, and closing it cleans up", %{
      conn: conn,
      sessions_before: before
    } do
      {:ok, view, _html} = live(conn, ~p"/imports")

      counts_before = counts()

      drop_file(view, "bb_sample.csv", @bb_sample)

      assert has_element?(view, "#inspect-drawer")
      assert counts() == counts_before
      assert length(staged_dirs(before)) == 1

      view |> element("#inspect-cancel") |> render_click()

      refute has_element?(view, "#inspect-drawer")
      assert counts() == counts_before
      assert staged_dirs(before) == []
    end

    test "confirming a drop imports it and records the content-addressed key", %{
      conn: conn,
      account: account,
      sessions_before: before
    } do
      {:ok, view, _html} = live(conn, ~p"/imports")

      drop_file(view, "bb_sample.csv", @bb_sample)

      expected = view |> element("#preview-new-count") |> render() |> extract_count()
      assert expected > 0

      html = view |> element("#confirm-import") |> render_click()

      assert Repo.aggregate(from(t in Transaction, where: t.account_id == ^account.id), :count) ==
               expected

      assert [run] = Repo.all(ImportRun)
      key = "#{Imports.content_hash(@bb_sample)}/bb_sample.csv"
      assert run.file_path == key
      assert [imported_file] = Repo.all(ImportedFile)
      assert imported_file.path == key

      refute html =~ ~s(id="inspect-drawer")
      assert html =~ "#{expected} transações importadas"
      assert staged_dirs(before) == []
    end

    test "a staged file gone at confirm time is refused and writes nothing", %{
      conn: conn,
      sessions_before: before
    } do
      {:ok, view, _html} = live(conn, ~p"/imports")

      counts_before = counts()

      drop_file(view, "bb_sample.csv", @bb_sample)

      assert [dir] = staged_dirs(before)
      File.rm_rf!(dir)

      html = view |> element("#confirm-import") |> render_click()

      assert html =~ "O arquivo solto não está mais disponível. Solte-o novamente."
      assert counts() == counts_before
      refute has_element?(view, "#inspect-drawer")
    end

    test "an ambiguous account choice waits for the operator", %{conn: conn, account: account} do
      # The bank hint of the BB sample is "Banco do Brasil": with the two
      # candidates banking elsewhere it matches neither, so no rule can fire.
      {:ok, _} = CashLens.Accounts.update_account(account, %{accepts_import: false})
      account_fixture(bank: "Bradesco", name: "Conta Um", parser_type: "bb_csv")
      second = account_fixture(bank: "Santander", name: "Conta Dois", parser_type: "bb_csv")

      {:ok, view, _html} = live(conn, ~p"/imports")

      html = drop_file(view, "bb_sample.csv", @bb_sample)

      assert html =~ ~s(id="drop-account")
      assert html =~ "Escolha a conta desta importação."
      assert preview_rows(view) == []
      assert has_element?(view, "#confirm-import[disabled]")

      select_account(view, second)

      assert preview_rows(view) != []
      refute has_element?(view, "#confirm-import[disabled]")
    end

    test "no compatible account opens the drawer on the error block", %{
      conn: conn,
      sessions_before: before
    } do
      {:ok, view, _html} = live(conn, ~p"/imports")

      html = drop_file(view, "ourocard.txt", @ourocard_sample)

      assert html =~ ~s(id="inspect-error")
      assert html =~ "Nenhuma conta compatível com este formato."
      refute has_element?(view, "#confirm-import")

      view |> element("#inspect-cancel") |> render_click()

      assert staged_dirs(before) == []
    end

    test "a second drop replaces the first, leaving one staging directory", %{
      conn: conn,
      sessions_before: before
    } do
      account_fixture(bank: "Itaú", name: "Conta OFX", parser_type: "standard_ofx")

      {:ok, view, _html} = live(conn, ~p"/imports")

      drop_file(view, "bb_sample.csv", @bb_sample)
      assert has_element?(view, "#inspect-drawer")

      html = drop_file(view, "extrato.ofx", @ofx_sample)

      assert html =~ ~s(id="inspect-drawer")
      assert html =~ "extrato.ofx"
      refute html =~ "bb_sample.csv"
      assert detection(view) =~ "OFX"

      assert [dir] = staged_dirs(before)
      assert Path.basename(dir) == Imports.content_hash(@ofx_sample)
    end

    test "a drop replaces an open folder inspection", %{conn: conn, root: root} do
      account_fixture(bank: "Itaú", name: "Conta OFX", parser_type: "standard_ofx")
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      assert has_element?(view, "#inspect-drawer")

      html = drop_file(view, "extrato.ofx", @ofx_sample)

      assert html =~ ~s(id="inspect-drawer")
      assert view |> element("#inspect-path") |> render() =~ "extrato.ofx"
      refute view |> element("#inspect-path") |> render() =~ "bb/extrato.csv"
      assert detection(view) =~ "OFX"
    end

    test "inspecting a folder entry while a drop is open discards the drop", %{
      conn: conn,
      root: root,
      sessions_before: before
    } do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, view, _html} = live(conn, ~p"/imports")

      drop_file(view, "extrato.ofx", @ofx_sample)
      assert [staged] = staged_dirs(before)

      html =
        view
        |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
        |> render_click()

      assert html =~ ~s(id="inspect-drawer")
      assert view |> element("#inspect-path") |> render() =~ "bb/extrato.csv"
      refute File.exists?(staged)
      assert staged_dirs(before) == []
      refute has_element?(view, "#drop-detection")
      assert :sys.get_state(view.pid).socket.assigns.drop == nil
    end

    test "mount sweeps stale session directories and keeps fresh ones", %{conn: conn} do
      stale = Path.join(Imports.drop_root(), "stale#{System.unique_integer([:positive])}")
      fresh = Path.join(Imports.drop_root(), "fresh#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(stale, "x"))
      File.mkdir_p!(Path.join(fresh, "x"))
      on_exit(fn -> Enum.each([stale, fresh], &File.rm_rf!/1) end)

      File.touch!(stale, System.os_time(:second) - 25 * 60 * 60)

      {:ok, _view, _html} = live(conn, ~p"/imports")

      refute File.dir?(stale)
      assert File.dir?(fresh)
    end

    test "terminating the LiveView removes the session directory", %{
      conn: conn,
      sessions_before: before
    } do
      {:ok, view, _html} = live(conn, ~p"/imports")

      drop_file(view, "bb_sample.csv", @bb_sample)
      assert length(staged_dirs(before)) == 1

      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      assert new_sessions(before) == []
    end
  end

  describe "installment regrouping after a confirmed import" do
    alias CashLens.Imports.ImportRun
    alias CashLens.Installments.InstallmentGroup
    alias CashLens.Parsers.Ingestor
    alias CashLens.Repo
    alias CashLens.Transactions.Transaction

    # An OFX carrying a single "PARC 03/10" purchase. OFX is used rather than
    # the BB CSV because the CSV parser strips `dd/mm` runs out of descriptions,
    # which would destroy the installment marker before it reaches the database.
    # The posting date is old enough that the parcel's billing month
    # (date + 2 months) is in the past, so the regrouping keeps the row.
    @parc_ofx """
    <OFX>
    <STMTTRN>
    <TRNTYPE>DEBIT</TRNTYPE>
    <DTPOSTED>20260110120000</DTPOSTED>
    <TRNAMT>-90.00</TRNAMT>
    <MEMO>COMPRA LOJA PARCELADA PARC 03/10</MEMO>
    </STMTTRN>
    </OFX>
    """

    @grouped_clause " • 1 transações agrupadas em parcelamentos"

    setup do
      before = session_names()
      on_exit(fn -> Enum.each(new_sessions(before), &File.rm_rf!/1) end)

      ofx_account =
        account_fixture(bank: "Itaú", name: "Conta OFX", parser_type: "standard_ofx")

      {:ok, sessions_before: before, ofx_account: ofx_account}
    end

    defp ofx_account_folder(root) do
      dir = Path.join(root, "itau")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".account"),
        "bank: Itaú\naccount: Conta OFX\nparser: standard_ofx\n"
      )

      dir
    end

    defp grouped_transactions do
      Repo.all(from t in Transaction, where: not is_nil(t.installment_group_id))
    end

    test "confirming a folder entry groups its installment purchase", %{
      conn: conn,
      root: root
    } do
      dir = ofx_account_folder(root)
      write_file(dir, "extrato.ofx", @parc_ofx)

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="itau/extrato.ofx"] [data-role="inspect"]))
      |> render_click()

      html = view |> element("#confirm-import") |> render_click()

      assert [group] = Repo.all(InstallmentGroup)
      assert group.installments == 10
      assert [transaction] = grouped_transactions()
      assert transaction.installment_group_id == group.id

      assert html =~ @grouped_clause
    end

    test "confirming a dropped file groups its installment purchase", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/imports")

      drop_file(view, "extrato_parc.ofx", @parc_ofx)

      html = view |> element("#confirm-import") |> render_click()

      assert [group] = Repo.all(InstallmentGroup)
      assert [transaction] = grouped_transactions()
      assert transaction.installment_group_id == group.id

      assert html =~ @grouped_clause
    end

    test "a confirm that imports nothing neither groups nor mentions parcelamentos", %{
      conn: conn,
      root: root,
      ofx_account: ofx_account
    } do
      dir = ofx_account_folder(root)
      file = write_file(dir, "extrato.ofx", @parc_ofx)

      # Imported outside the LiveView, so the installment row is already in the
      # database and still ungrouped: a scan running on the confirm below would
      # grab it. That is what keeps the assertions here from being vacuous.
      {:ok, _summary} = Ingestor.import_file(ofx_account, file, import_root: root)
      assert grouped_transactions() == []

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="itau/extrato.ofx"] [data-role="inspect"]))
      |> render_click()

      assert view |> element("#preview-new-count") |> render() |> extract_count() == 0

      html = view |> element("#confirm-import") |> render_click()

      assert Repo.all(InstallmentGroup) == []
      assert grouped_transactions() == []
      assert html =~ "0 transações importadas"
      refute html =~ "agrupadas em parcelamentos"
    end

    test "the drawer counters equal the import_runs row the confirm writes", %{
      conn: conn,
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      file = write_file(dir, "extrato.csv", @bb_sample)

      {:ok, %{imported: already}} = Ingestor.import_file(account, file, import_root: root)
      assert already > 0

      File.write!(file, @bb_sample <> "28/02/2026,1234,5678,COMPRA NOVA,321.654,-12.34,\n")

      {:ok, view, _html} = live(conn, ~p"/imports")

      view
      |> element(~s(tr[data-path="bb/extrato.csv"] [data-role="inspect"]))
      |> render_click()

      new_count = view |> element("#preview-new-count") |> render() |> extract_count()
      skipped_count = view |> element("#preview-skipped-count") |> render() |> extract_count()

      assert new_count == 1
      assert skipped_count == already

      # The direct import above already wrote a run of its own; only the one the
      # confirm adds is compared against the drawer.
      previous_run_ids = Repo.all(from r in ImportRun, select: r.id)

      view |> element("#confirm-import") |> render_click()

      assert [run] = Repo.all(from r in ImportRun, where: r.id not in ^previous_run_ids)
      assert run.imported_count == new_count
      assert run.skipped_count == skipped_count
    end
  end
end
