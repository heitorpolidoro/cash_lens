defmodule CashLensWeb.BaseLive do
  @moduledoc false
  use CashLensWeb, :live_view

  import CashLensWeb.CoreComponents, except: [button: 1, table: 1]
  import CashLens.Utils
  import SaladUI.Button
  import SaladUI.Table

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
        parts = String.split(params["target"], ".")
        {base_module, module_name} = {Enum.join(Enum.drop(parts, -1), "."), List.last(parts)}

        module_name_downcase = String.downcase(module_name)
        method = "create_#{module_name_downcase}"
        attributes = params[module_name_downcase]

        attributes = Map.replace(attributes, "user_id", socket.assigns.current_user.id)

        case apply(
          String.to_existing_atom(base_module),
          String.to_existing_atom(method),
          [attributes])
        do
          {:ok, _} ->
            {:noreply,
              socket
                |> put_flash(:info, "#{module_name} created successfully")}
            {:error, %Ecto.Changeset{} = changeset} ->
            errors = changeset.errors
            |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
            |> Enum.join(" - ")
              {:noreply,
               socket
               |> put_flash(:error, errors)}
        end
      end
    end
  end

  def crud(%{"target": target, "list": list} = assigns) do
    IO.inspect(assigns)
    name = Module.split(target) |> List.last()
    plural_name = Map.get(assigns, :plural, "#{name}s")
    formatter = Map.get(assigns, :formatter, [])

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

    list = list
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
    ~H"""
    <h1 class="text-2xl font-semibold">{plural_name}</h1>
    <div class="bg-white shadow-md">
      <div class="px-4 py-5 sm:p-6">
        <div class="flex justify-between items-center">
          <h3 class="text-lg font-medium">{plural_name} list</h3>
            <.button phx-click={show_modal("crud_modal")}>New {name}</.button>
        </div>

        <.crud_modal target={target} formatter={@formatter} fields={fields}/>
        <div class="mt-5">
          <%= if Enum.empty?(list) do %>
            <p class="text-sm text-gray-500">No accounts yet. Create one to get started.</p>
          <% else %>
            <.table>
              <.table_header>
                <.table_row>
                  <%= for {field, type, label, options} <- show_fields do %>
                    <.table_head>{label}</.table_head>
                  <% end %>
                </.table_row>
              </.table_header>
              <.table_body>
                <%= for item <- list do %>
                  <.table_row>
                    <%= for {field, type, label, options} <- show_fields do %>
                      <.table_cell>{Map.get(item, field)}</.table_cell>
                    <% end %>
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
    ~H"""
          <.modal id="crud_modal">
            <.simple_form
            :let={f}
            for={changeset}
            phx-submit="save"
            >
              <h3 class="text-lg font-bold">Hello!</h3>
              <input type="hidden" name="target" value={target} />
              <%= for {field, type, label, options} <- @fields do %>
                <%= case field do %>
                  <% :user_id -> %>
                    <.input type="hidden" field={f[field]} value={""} />
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
