defmodule CashLensWeb.ImportLiveUploadTest do
  @moduledoc """
  Server-side validation of the import dropzone: extension allow-list, 10 MB
  cap and content checks. A rejected drop shows an error on the screen and
  ingests nothing.
  """
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CashLens.Imports
  alias CashLens.Repo

  @bb_sample File.read!("test/support/fixtures/files/bb_sample.csv")

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

  defp staged_files(before) do
    before
    |> new_sessions()
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join(dir, "**/*")) end)
    |> Enum.filter(&File.regular?/1)
  end

  defp drop(view, name, content) do
    view
    |> file_input("#dropzone-form", :drop, [
      %{name: name, content: content, type: "application/octet-stream"}
    ])
    |> render_upload(name)

    render(view)
  end

  defp row_counts do
    for table <- ~w(transactions imported_files import_runs), into: %{} do
      {table, Repo.query!("SELECT count(*) FROM #{table}").rows}
    end
  end

  defp assert_rejected(html, view, counts, before) do
    assert html =~ ~s(id="drop-error")
    refute html =~ ~s(id="inspect-drawer")
    assert row_counts() == counts
    assert staged_files(before) == []
    assert render(view) =~ ~s(id="drop-error")
  end

  test "a valid csv is accepted", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/imports")
    html = drop(view, "bb_sample.csv", @bb_sample)

    refute html =~ ~s(id="drop-error")
    assert html =~ ~s(id="inspect-drawer")
  end

  test "a latin-1 encoded csv is still accepted", %{conn: conn} do
    latin1 = :unicode.characters_to_binary(@bb_sample <> "Descrição\n", :utf8, :latin1)
    {:ok, view, _} = live(conn, ~p"/imports")

    refute drop(view, "bb_sample.csv", latin1) =~ ~s(id="drop-error")
  end

  test "a disallowed extension is rejected", %{conn: conn, sessions_before: before} do
    {:ok, view, _} = live(conn, ~p"/imports")
    counts = row_counts()

    html = drop(view, "malware.exe", "just text")

    assert html =~ "Extensão não aceita"
    assert_rejected(html, view, counts, before)
  end

  test "a file over 10 MB is rejected", %{conn: conn, sessions_before: before} do
    {:ok, view, _} = live(conn, ~p"/imports")
    counts = row_counts()

    html = drop(view, "big.csv", String.duplicate("a,b\n", 2_600_000))

    assert html =~ "limite é 10 MB"
    assert_rejected(html, view, counts, before)
  end

  test "a pdf without the %PDF header is rejected", %{conn: conn, sessions_before: before} do
    {:ok, view, _} = live(conn, ~p"/imports")
    counts = row_counts()

    html = drop(view, "fatura.pdf", "<html>not a pdf</html>")

    assert html =~ "conteúdo não corresponde"
    assert_rejected(html, view, counts, before)
  end

  test "a csv containing NUL bytes is rejected", %{conn: conn, sessions_before: before} do
    {:ok, view, _} = live(conn, ~p"/imports")
    counts = row_counts()

    html = drop(view, "extrato.csv", "Data,Valor\n01/01/2026,\0\0\0 10.00\n")

    assert html =~ "conteúdo não corresponde"
    assert_rejected(html, view, counts, before)
  end

  test "the extension check is case-insensitive", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/imports")
    refute drop(view, "BB_SAMPLE.CSV", @bb_sample) =~ ~s(id="drop-error")
  end

  describe "Imports.validate_drop/2" do
    @tag :tmp_dir
    test "checks extension, size and content against the file on disk", %{tmp_dir: dir} do
      path = Path.join(dir, "f")

      File.write!(path, "%PDF-1.4 ok")
      assert :ok = Imports.validate_drop(path, "a.PDF")

      File.write!(path, "plain text")
      assert {:error, :content_mismatch} = Imports.validate_drop(path, "a.pdf")
      assert :ok = Imports.validate_drop(path, "a.ofx")
      assert {:error, :extension} = Imports.validate_drop(path, "a.sh")
      assert {:error, :extension} = Imports.validate_drop(path, "noext")

      File.write!(path, <<1, 2, 3, 4>>)
      assert {:error, :content_mismatch} = Imports.validate_drop(path, "a.txt")

      File.write!(path, String.duplicate("a", 10_000_001))
      assert {:error, :too_large} = Imports.validate_drop(path, "a.csv")

      assert {:error, :unreadable} = Imports.validate_drop(Path.join(dir, "missing"), "a.csv")
    end
  end
end
