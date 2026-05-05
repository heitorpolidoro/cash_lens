defmodule CashLensWeb.TransactionLive.ImportModalComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures

  # A fully functioning test LiveView
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
    parser_type: "ofx"
  }

  setup do
    account = account_fixture(@create_attrs)
    {:ok, account: account}
  end

  test "renders the modal with accounts", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, HostLive)

    assert html =~ "Import Statements"
    assert html =~ "Test Account"
  end

  test "handles save_import with no file", %{conn: conn, account: account} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    assert render(view) =~ "Error: No file selected."
  end

  test "handles save_import with uploaded file (sync mode)", %{conn: conn, account: account} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "test.csv", content: "some,csv,content", type: "text/csv"}
      ])

    render_upload(upload, "test.csv")
    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    # Parser type "ofx" doesn't match "standard_ofx" in Ingestor.parse/2 → error
    assert render(view) =~ "Error:"
  end

  test "handles save_import with uploaded file (async mode)", %{conn: conn, account: account} do
    Application.put_env(:cash_lens, :sql_sandbox, false)
    on_exit(fn -> Application.put_env(:cash_lens, :sql_sandbox, true) end)

    {:ok, view, _html} = live_isolated(conn, HostLive)

    upload =
      file_input(view, "#upload-form", :statement, [
        %{name: "test.csv", content: "some,csv,content", type: "text/csv"}
      ])

    render_upload(upload, "test.csv")
    view |> element("#upload-form") |> render_submit(%{"account_id" => account.id})

    # Wait for async Task to complete and send the error message
    Process.sleep(100)
    assert render(view) =~ "Error:"
  end
end
