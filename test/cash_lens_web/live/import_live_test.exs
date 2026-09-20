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

  describe "later parts" do
    test "no dropzone, inspection modal or history table is rendered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/imports")

      refute html =~ ~s(id="dropzone")
      refute html =~ ~s(id="inspection-modal")
      refute html =~ ~s(id="import-history")
    end
  end
end
