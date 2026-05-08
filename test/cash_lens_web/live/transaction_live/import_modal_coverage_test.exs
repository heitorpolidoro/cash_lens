defmodule CashLensWeb.TransactionLive.ImportModalCoverageTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures

  alias CashLensWeb.TransactionLive.ImportModalComponent
  alias Ecto.Adapters.SQL.Sandbox

  defmodule HostLive do
    use Phoenix.LiveView
    alias CashLensWeb.TransactionLive.ImportModalComponent
    import CashLensWeb.CoreComponents

    def mount(_params, session, socket) do
      {:ok, assign(socket, show: true, account_id: session["account_id"] || "123")}
    end

    def handle_info({:import_success, count}, socket),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :info, "Success: #{count}")}

    def handle_info({:import_error, reason}, socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Error: #{reason}")}
    end

    def handle_info(:close_import_modal, socket),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :info, "Modal closed")}

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <.live_component module={ImportModalComponent} id="import-modal" show={@show} />
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      """
    end
  end

  @create_attrs %{
    name: "Test Account",
    bank: "Test Bank",
    accepts_import: true,
    parser_type: "bb_csv"
  }

  setup do
    Sandbox.mode(CashLens.Repo, {:shared, self()})
    account = account_fixture(@create_attrs)
    {:ok, account: account}
  end

  test "renders account bank abbreviation for accounts without icon", %{
    conn: conn,
    account: account
  } do
    {:ok, _view, html} = live_isolated(conn, HostLive, session: %{"account_id" => account.id})

    # Accounts without icon show the first 2 chars of bank or name (String.slice branch)
    assert html =~ String.slice(account.bank || account.name, 0..1)
  end

  test "renders account icon when present", %{conn: conn} do
    _account =
      account_fixture(%{
        name: "Icon Account",
        icon: "https://example.com/icon.png",
        accepts_import: true
      })

    {:ok, _view, html} = live_isolated(conn, HostLive)

    assert html =~ "https://example.com/icon.png"
  end

  test "validate_import with account_id selected", %{conn: conn, account: account} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    result = view |> element("#upload-form") |> render_change(%{"account_id" => account.id})

    assert result =~ "import-modal"
  end

  test "validate_import without account_id (catch-all clause)", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    result = view |> element("#upload-form") |> render_change(%{})

    assert result =~ "import-modal"
  end

  test "close event sends :close_import_modal to parent", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    view |> element("[aria-label='close']") |> render_click()

    assert render(view) =~ "Modal closed"
  end

  test "save_import with file - error from unsupported parser", %{conn: conn} do
    no_parser_account =
      account_fixture(%{
        name: "No Parser",
        bank: "Bank",
        accepts_import: true,
        parser_type: "unknown_type"
      })

    {:ok, view, _html} = live_isolated(conn, HostLive)

    csv_content = "header\nrow1"

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "test.csv", content: csv_content, type: "text/csv"}
      ])

    render_upload(upload, "test.csv")

    view |> element("#upload-form") |> render_submit(%{"account_id" => no_parser_account.id})

    assert render(view) =~ "Error"
  end

  test "save_import with file - success using bb_csv parser", %{conn: conn, account: account} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    csv_content =
      case File.read("test/support/fixtures/files/bb_sample.csv") do
        {:ok, content} -> content
        {:error, _} -> raise "Missing test fixture: test/support/fixtures/files/bb_sample.csv"
      end

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "bb_sample.csv", content: csv_content, type: "text/csv"}
      ])

    render_upload(upload, "bb_sample.csv")

    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    assert render(view) =~ "Success"
  end

  test "in production-like environment, it starts a Task", %{conn: conn, account: account} do
    parent = self()

    # Simulate production environment where sandbox is false and we have a custom task starter
    Application.put_env(:cash_lens, :sql_sandbox, false)

    Application.put_env(:cash_lens, :task_start_fn, fn _func ->
      send(parent, :task_dispatched)
      {:ok, self()}
    end)

    on_exit(fn ->
      Application.put_env(:cash_lens, :sql_sandbox, true)
      Application.delete_env(:cash_lens, :task_start_fn)
    end)

    {:ok, view, _html} = live_isolated(conn, HostLive)

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "test.csv", content: "header\nrow", type: "text/csv"}
      ])

    render_upload(upload, "test.csv")

    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    assert_receive :task_dispatched
  end

  test "save_import without file sends error to parent", %{conn: conn, account: account} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    assert render(view) =~ "Error: No file selected."
  end

  test "cancel-upload removes file entry", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "test.csv", content: "data", type: "text/csv"}
      ])

    render_upload(upload, "test.csv", 50)

    html_with_file = render(view)
    assert html_with_file =~ "test.csv"

    view |> element("button[phx-click*='cancel-upload']") |> render_click()

    assert render(view) =~ "import-modal"
  end

  test "cancel-upload removes directory file entry", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    upload =
      file_input(view, "#upload-form", :directory_statement, [
        %{name: "test_dir.csv", content: "data", type: "text/csv"}
      ])

    render_upload(upload, "test_dir.csv", 50)

    html_with_file = render(view)
    assert html_with_file =~ "test_dir.csv"

    # Find the cancel button for the directory statement
    view |> element("button[phx-click*='directory_statement']") |> render_click()

    assert render(view) =~ "import-modal"
  end

  test "import_directory triggers directory ingestion", %{conn: conn, account: account} do
    # Requires a directory to exist at /app/statements. We will mock or catch the error.
    # Since /app/statements doesn't exist locally, it will likely return an error.
    # We remove the HostLive custom button and just use the hidden button in the component.
    {:ok, view, _html} = live_isolated(conn, HostLive)

    # First, select an account so @import_account_id is populated
    view |> element("#upload-form") |> render_change(%{"account_id" => account.id})

    # Trigger via the hidden button inside the component
    view |> element("#import-dir-hidden-btn") |> render_click()

    # The flash update comes asynchronously. We use assert_patch or similar to wait,
    # but since it's a flash without navigation, we can just check render(view)
    # if it doesn't work we sleep. Wait, `render_click` on a component with phx-target
    # will wait for the component update, but not the parent LiveView's `handle_info`.
    Process.sleep(50)

    html = render(view)

    assert html =~ "Error: Path is not a directory"
  end
end
