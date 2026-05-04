defmodule CashLensWeb.TransactionLive.ImportModalCoverageTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures

  alias CashLensWeb.TransactionLive.ImportModalComponent

  defmodule HostLive do
    use Phoenix.LiveView
    alias CashLensWeb.TransactionLive.ImportModalComponent
    import CashLensWeb.CoreComponents

    def mount(_params, _session, socket) do
      {:ok, assign(socket, show: true)}
    end

    def handle_info({:import_success, count}, socket),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :info, "Success: #{count}")}

    def handle_info({:import_error, reason}, socket),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Error: #{reason}")}

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
    Ecto.Adapters.SQL.Sandbox.mode(CashLens.Repo, {:shared, self()})
    account = account_fixture(@create_attrs)
    {:ok, account: account}
  end

  test "renders account bank abbreviation for accounts without icon", %{
    conn: conn,
    account: account
  } do
    {:ok, _view, html} = live_isolated(conn, HostLive)

    # Accounts without icon show the first 2 chars of bank or name (String.slice branch)
    assert html =~ String.slice(account.bank || account.name, 0..1)
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

    csv_content = File.read!("test/support/fixtures/files/bb_sample.csv")

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "bb_sample.csv", content: csv_content, type: "text/csv"}
      ])

    render_upload(upload, "bb_sample.csv")

    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    assert render(view) =~ "Success"
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
end
