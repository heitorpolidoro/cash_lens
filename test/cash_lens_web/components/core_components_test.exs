defmodule CashLensWeb.CoreComponentsTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLensWeb.CoreComponents
  alias Phoenix.LiveView.JS

  # A host component to render CoreComponents with slots properly
  defmodule Host do
    use Phoenix.Component
    import CashLensWeb.CoreComponents
    alias Phoenix.LiveView.JS

    def render(assigns) do
      ~H"""
      <div id="host">
        <.flash kind={:info} flash={%{"info" => "info message"}} />
        <.flash kind={:error} title="Error Title">error message</.flash>

        <.button variant="primary">Primary</.button>
        <.button variant="outline" href="/test">Outline Link</.button>
        <.button variant="white" navigate="/test">White Navigate</.button>
        <.button patch="/test">Standard Patch</.button>

        <.input name="text" value="val" label="Text Input" />
        <.input name="check" type="checkbox" value="true" label="Checkbox" />
        <.input name="check_nil" type="checkbox" value={nil} label="Checkbox Nil" />
        <.input name="sel_empty" type="select" value="" options={[]} label="Select Empty" />
        <.input
          name="sel"
          type="select"
          value="A"
          options={["A", "B"]}
          prompt="Select..."
          label="Select"
        />
        <.input name="area" type="textarea" value="text" label="Textarea" />
        <.input name="err" value="" errors={["is invalid"]} label="Error Input" />

        <.input
          id="custom_id"
          field={Phoenix.Component.to_form(%{"name" => "test"}, as: :f, action: :validate)[:name]}
          label="Explicit ID Input"
        />

        <.header>
          Title
          <:subtitle>Subtitle</:subtitle>
          <:actions><.button>Action</.button></:actions>
        </.header>

        <.header>Simple Header</.header>

        <.table
          id="test-table-1"
          rows={[%{id: 1, name: "Item 1"}]}
          row_click={fn row -> JS.navigate("/transactions/#{row.id}") end}
        >
          <:col :let={row} label="Name">{row.name}</:col>
          <:action :let={row}>Delete {row.id}</:action>
        </.table>

        <.table
          id="test-table-2"
          rows={[%{id: 2, name: "Item 2"}]}
          row_id={fn row -> "row-#{row.id}" end}
        >
          <:col :let={row} label="Name">{row.name}</:col>
        </.table>

        <.list>
          <:item title="Title 1">Content 1</:item>
          <:item title="Title 2">Content 2</:item>
        </.list>

        <.modal id="test-modal" show>
          Modal Content
        </.modal>

        <.icon name="hero-pencil" class="custom-class" />
        <.icon name="hero-pencil" />
      </div>
      """
    end
  end

  # A real LiveView to test LiveStream branch of table component
  defmodule StreamLive do
    use Phoenix.LiveView
    import CashLensWeb.CoreComponents

    def mount(_params, _session, socket) do
      {:ok, stream(socket, :items, [%{id: 1, name: "Item 1"}])}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.table id="stream-table-1" rows={@streams.items}>
          <:col :let={{_id, item}} label="Name">{item.name}</:col>
        </.table>
        <.table id="stream-table-2" rows={@streams.items} row_id={fn {id, _item} -> "custom-#{id}" end}>
          <:col :let={{_id, item}} label="Name">{item.name}</:col>
        </.table>
      </div>
      """
    end
  end

  test "renders all core components successfully" do
    html = render_component(&Host.render/1, %{})

    # Flash
    assert html =~ "info message"
    assert html =~ "Error Title"
    assert html =~ "error message"

    # Button
    assert html =~ "btn-primary"
    assert html =~ "btn-outline"
    assert html =~ "White Navigate"
    assert html =~ "Standard Patch"

    # Input
    assert html =~ "Text Input"
    assert html =~ "Checkbox"
    assert html =~ "Select..."
    assert html =~ "is invalid"
    assert html =~ "custom_id"

    # Header
    assert html =~ "Title"
    assert html =~ "Subtitle"
    assert html =~ "Simple Header"

    # Table
    assert html =~ "Item 1"
    assert html =~ "Delete 1"
    assert html =~ "row-2"

    # List
    assert html =~ "Title 1"
    assert html =~ "Content 2"

    # Modal
    assert html =~ "test-modal"
    assert html =~ "Modal Content"

    # Icon
    assert html =~ "hero-pencil"
    assert html =~ "custom-class"
  end

  test "renders table with stream" do
    {:ok, _view, html} = live_isolated(build_conn(), StreamLive)
    assert html =~ "Item 1"
    assert html =~ "phx-update=\"stream\""
  end

  test "translate_error handles pluralization" do
    assert translate_error({"should be %{count} character(s)", [count: 1]}) ==
             "should be 1 character(s)"

    assert translate_error({"should be %{count} character(s)", [count: 2]}) ==
             "should be 2 character(s)"
  end

  test "show/hide helpers return JS commands" do
    assert %Phoenix.LiveView.JS{} = show("selector")
    assert %Phoenix.LiveView.JS{} = hide("selector")
  end
end
