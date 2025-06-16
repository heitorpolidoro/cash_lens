defmodule CashLensWeb.BaseLive do
  @moduledoc false
  use CashLensWeb, :live_view

  import CashLensWeb.CoreComponents, except: [button: 1, table: 1, icon: 1]
  import CashLens.Utils
  import SaladUI.Button
  import SaladUI.Table
  import SaladUI.Tooltip
  import SaladUI.Icon
  require Logger

  def extract_module_name(%{:target => target}) when is_atom(target) do
    extract_module_name(%{"target" => Atom.to_string(target)})
  end
  def extract_module_name(%{"target" => target}) do
    parts = String.split(target, ".")
    {Enum.join(Enum.drop(parts, -1), "."), List.last(parts)}
  end

  def call_method_if_exists(base_module, method_name, args) do
    call_method(base_module, method_name, "", args, False)
  end

  def call_method(base_module, method_name, method_prefix, args, rize_error_if_dont_exists \\ True)
  def call_method(base_module, method_name, "", args, rize_error_if_dont_exists) do
    try do
      apply(String.to_existing_atom(base_module), method_name, args)
    rescue error -> error
      if rize_error_if_dont_exists do
        Logger.error([String.to_existing_atom(base_module), method_name, args])
        raise error
      else
        nil
      end
    end
  end
  def call_method(base_module, module_name, method_prefix, args, rize_error_if_dont_exists) do
    method = "#{method_prefix}_#{String.downcase(module_name)}"
    call_method(base_module, String.to_existing_atom(method), "", args)
  end

  def on_mount(:default, _params, %{"current_user" => current_user} = _session, socket) do
    {:cont, assign(socket, current_user: current_user, changeset: nil)}
  end

  defmacro __using__(_) do
    quote do
      def handle_params(_params, uri, socket) do
        {:noreply, assign(socket, :current_path, URI.parse(uri).path)}
      end

      def handle_info({:flash, level, message}, socket) do
        {:noreply, put_flash(socket, level, message)}
      end

      def handle_event("save", params, socket) do
        IO.puts("-----------------\nCALL save\n-----------------")

        {base_module, module_name} = extract_module_name(params)
        module_name_downcase = String.downcase(module_name)
        current_user_id = socket.assigns.current_user.id

        attributes =
          params[module_name_downcase]
          |> Map.put("user_id", current_user_id)

        case call_method(base_module, module_name, "create", [attributes]) do
          {:ok, item} ->
            item_str = call_method_if_exists(base_module, :to_str, [item]) || module_name
            {:noreply,
              socket
               |> put_flash(:info, "#{item_str} created successfully")}
          {:error, %Ecto.Changeset{} = changeset} ->
            errors = changeset.errors
            |> Enum.map(fn {field, {message, _}} -> "#{capitalize(field)}: #{message}" end)
            |> Enum.join(" - ")
              {:noreply,
               socket
               |> put_flash(:error, errors)}
        end
      end

      def handle_event("delete", %{"id" => id} = params, socket) do
        {base_module, module_name} = extract_module_name(params)

        # Get the item by ID
        item = call_method(base_module, module_name <> "!", "get", [id])

        # Delete the item
        case call_method(base_module, module_name, "delete", [item]) do
          {:ok, item} ->
            item_str = call_method_if_exists(base_module, :to_str, [item]) || module_name
            {:noreply,
             socket
             |> put_flash(:info, "#{item_str}##{id} deleted successfully")}
          {:error, %Ecto.Changeset{} = changeset} ->
            errors = changeset.errors
            |> Enum.map(fn {field, {message, _}} -> "#{capitalize(field)}: #{message}" end)
            |> Enum.join(" - ")
            {:noreply,
             socket
             |> put_flash(:error, errors)}
        end
      end
    end
  end

  def crud(%{"target": target} = assigns) do
#    IO.puts("-----------------\nCALL crud\n-----------------")
#    IO.inspect(assigns)
    formatter = Map.get(assigns, :formatter, %{})

    {base_module, module_name} = extract_module_name(assigns)
    module_name_downcase = String.downcase(module_name)

    plural_name = Map.get(assigns, :plural, "#{module_name}s")
    fields =
      target.__schema__(:fields)
      |> Enum.filter(fn k -> k not in [:inserted_at, :updated_at, :id] end)
      |> Enum.map(fn k ->
        {type, options} =
          case target.__schema__(:type, k) do
            {:parameterized, {_, type}} ->
              options =
                type.on_cast
                |> Map.keys
                |> Enum.map(fn value ->
                  if Map.has_key?(formatter, k) do
                    {Map.get(formatter, k).(value), value}
                  else
                    value
                  end
                end)
              {"select", options  }
            type -> {"text", []}
          end

        label = from_atom(k)
        {k, type, label, options}
      end)

    list =
      call_method(base_module, module_name <> "s", "list", [assigns.current_user.id])
      |> Enum.map(fn item ->
        fields
        |> Enum.reduce(item, fn f, acc ->
            if Map.has_key?(formatter, elem(f, 0)) do
              Map.put(acc, elem(f, 0), Map.get(formatter, elem(f, 0)).(Map.get(acc, elem(f, 0))))
            else
              acc
            end
          end)
      end)

    show_fields = Enum.filter(fields, fn tuple -> elem(tuple, 0) != :user_id end)
    assigns = assigns
      |> assign(target: target)
      |> assign(show_fields: show_fields)
#      |> assign(list: list)
#      |> assign(module_name: module_name_downcase)
#      |> assign(module_name_capitalize: module_name)
    ~H"""
    <h1 class="text-2xl font-semibold">{plural_name}</h1>
    <div class="bg-white shadow-md">
      <div class="px-4 py-5 sm:p-6">
        <div class="flex justify-between items-center">
          <h3 class="text-lg font-medium">{plural_name} list</h3>
            <.button phx-click={show_modal("crud_modal")}>New {module_name}</.button>
        </div>

        <.crud_modal target={@target} formatter={@formatter} fields={fields}/>
        <div class="mt-5">
          <%= if Enum.empty?(list) do %>
            <p class="text-sm text-gray-500">No accounts yet. Create one to get started.</p>
          <% else %>
            <.table>
              <.table_header>
                <.table_row>
                  <%= for {field, type, label, options} <- @show_fields do %>
                    <.table_head>{label}</.table_head>
                  <% end %>
                  <.table_head>Action</.table_head>
                </.table_row>
              </.table_header>
              <.table_body>
                <%= for item <- list do %>
                  <.table_row>
                    <%= for {field, type, label, options} <- show_fields do %>
                      <.table_cell>{Map.get(item, field)}</.table_cell>
                    <% end %>
                    <.table_cell>
                      <.tooltip>
                        <.tooltip_trigger>
                          <div phx-click="edit" phx-value-id={item.id} phx-value-target={@target} class="cursor-pointer">
                            <.icon name="hero-pencil-solid" class="h-5 w-5" />
                          </div>
                        </.tooltip_trigger>
                        <.tooltip_content>
                          <p>Edit</p>
                        </.tooltip_content>
                      </.tooltip>
                      <.tooltip>
                        <.tooltip_trigger>
                          <div phx-click="delete" phx-value-id={item.id} phx-value-target={@target} class="cursor-pointer">
                            <.icon name="hero-x-mark-solid" class="h-7 w-7 text-red-500" />
                          </div>
                        </.tooltip_trigger>
                        <.tooltip_content>
                          <p>Delete</p>
                        </.tooltip_content>
                      </.tooltip>
                    </.table_cell>
                  </.table_row>
                <% end %>
              </.table_body>
            </.table>
          <% end %>
        </div>

      </div>
    </div>
    """
  end

  def crud_modal(%{"target": target} = assigns) do

    changeset = target.changeset(struct(target, %{}), %{})
    assigns =
      assigns
        |> assign(target: target)
        |> assign(changeset: changeset)
    ~H"""
          <.modal id="crud_modal">
            <.simple_form
            :let={f}
            for={@changeset}
            phx-submit="save"
            >
              <input type="hidden" name="target" value={@target} />
              <%= for {field, type, label, options} <- @fields do %>
                <%= case field do %>
                  <% :user_id -> %>
                  <% _ -> %>
                    <.input label={label} field={f[field]} type={type} options={options}/>
                <% end %>
              <% end %>
              <:actions>
                <.button type="button" variant="secondary" phx-click={hide_modal("crud_modal")}>Cancel</.button>
                <.button  phx-click={hide_modal("crud_modal")}>Save</.button>
              </:actions>
            </.simple_form>
          </.modal>
      """
  end
end
