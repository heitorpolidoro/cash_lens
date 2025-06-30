defmodule CashLensWeb.BaseLive do
  @moduledoc """
  Base LiveView module that provides common functionality for CashLens LiveView components.

  This module serves as a foundation for other LiveView modules in the CashLens application.
  It provides:

  - Utility functions for extracting module information and dynamically calling methods
  - Common event handlers for CRUD operations through the `__using__` macro
  - Reusable UI components for displaying and managing data

  Modules that use `CashLensWeb.BaseLive` automatically inherit common event handlers
  for saving, deleting, and other operations, reducing code duplication across LiveView modules.
  """
  use CashLensWeb, :live_view
  alias CashLens.Utils

  import CashLensWeb.CoreComponents, except: [button: 1, table: 1, icon: 1]
  import SaladUI.Button
  import SaladUI.Table
  import SaladUI.Tooltip
  import SaladUI.Icon
  require Logger

  @doc """
  LiveView on_mount callback that sets up the socket with the current user.

  This callback is called when a LiveView that uses this module is mounted.
  It assigns the current user to the socket and initializes the changeset to nil.

  ## Parameters

  - `_params` - The parameters passed to the LiveView
  - `session` - The session data, expected to contain the current user
  - `socket` - The LiveView socket

  ## Returns

  `{:cont, socket}` with the current user and nil changeset assigned to the socket.
  """
  def on_mount(:default, _params, %{"current_user" => current_user} = _session, socket) do
    {:cont, assign(socket, current_user: current_user, changeset: nil)}
  end

  @doc """
  Provides common event handlers and functionality to LiveView modules.

  When a module uses `CashLensWeb.BaseLive`, it automatically includes:

  - A `handle_params/3` callback that assigns the current path to the socket
  - A `handle_info/2` callback for handling flash messages
  - A `handle_event/3` callback for "save" events that creates new items
  - A `handle_event/3` callback for "delete" events that deletes items

  These callbacks use the utility functions in this module to dynamically
  call the appropriate context functions based on the parameters.
  """
  defmacro __using__(_) do
    quote do
      def handle_params(_params, uri, socket) do
        {:noreply, assign(socket, :current_path, URI.parse(uri).path)}
      end

      def handle_info({:flash, level, message}, socket) do
        {:noreply, put_flash(socket, level, message)}
      end

      def handle_event("save", %{"target" => target} = params, socket) do
        current_user_id = socket.assigns.current_user.id

        attributes =
        params
          |> Map.drop(["target"])
          |> Map.values()
          |> List.first()
          |> Map.put("user_id", current_user_id)

        case call_method(target, :create, [attributes]) do
          {:ok, item} ->
            item_str = call_method_if_exists(target, :to_str, [item]) || target
            {:noreply,
              socket |> put_flash(:info, "#{item_str} created successfully")}
          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            {:noreply,
              socket |> put_flash(:error, errors)}
        end
      end

      def handle_event("delete", %{"id" => id, "target" => target} = params, socket) do
        # Get the item by ID
        item = call_method(target, :get, [id])

        # Delete the item
        case call_method(target, :delete, [item]) do
          {:ok, item} ->
            item_str = call_method_if_exists(target, :to_str, [item]) || target
            {:noreply,
              socket |> put_flash(:info, "#{item_str}##{id} deleted successfully")}
          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            {:noreply,
              socket |> put_flash(:error, errors)}
          {:error, error} ->
            {:noreply,
              socket |> put_flash(:error, error)}
        end
      end
    end
  end

  @doc """
  Extracts module information from a target module.

  This function parses a module name and returns a tuple containing:
  - The base module name (without the last part)
  - The last part of the module name (typically the entity name)
  - The second-to-last part of the module name (typically the plural form of the entity)

  ## Examples

      iex> extract_module_info(CashLens.Accounts.Account)
      {"CashLens.Accounts", "Account", "Accounts"}

      iex> extract_module_info(%{"target" => "CashLens.Accounts.Account"})
      {"CashLens.Accounts", "Account", "Accounts"}
  """
  def extract_module_info(target) when is_atom(target) do
    extract_module_info(%{"target" => Atom.to_string(target)})
  end
  def extract_module_info(%{:target => target}) when is_atom(target) do
    extract_module_info(%{"target" => Atom.to_string(target)})
  end
  def extract_module_info(%{"target" => target}) do
    parts = String.split(target, ".")
    {List.last(parts), List.last(Enum.drop(parts, -1))}
  end

  @doc """
  Calls a method on a module if it exists, returning nil if the method doesn't exist.

  This is a convenience wrapper around `call_method/5` that suppresses errors when the method doesn't exist.

  ## Parameters

  - `base_module` - The string name of the module to call the method on
  - `method_name` - The atom name of the method to call
  - `args` - The list of arguments to pass to the method

  ## Returns

  The result of the method call, or `nil` if the method doesn't exist.

  ## Examples

      iex> call_method_if_exists("CashLens.Accounts.Account", :to_str, [account])
      "Personal Account"

      iex> call_method_if_exists("CashLens.Accounts.Account", :nonexistent_method, [])
      nil
  """
  def call_method_if_exists(target, method, args) do
    call_method(target, method, args, false)
  end

  @doc """
  Dynamically calls a method on a module.

  This function provides a flexible way to call methods on modules dynamically, with options
  for error handling and method name construction.

  ## Parameters

  - `base_module` - The string name of the module to call the method on
  - `method_name` - The atom name of the method to call, or a string to be combined with `method_prefix`
  - `method_prefix` - A string prefix to combine with `method_name` (when `method_name` is a string)
  - `args` - The list of arguments to pass to the method
  - `raise_error_if_not_exists` - Whether to raise an error if the method doesn't exist (default: true)

  ## Returns

  The result of the method call, or `nil` if the method doesn't exist and `raise_error_if_not_exists` is false.

  ## Examples

      iex> call_method("CashLens.Accounts", :list, "", [user_id])
      [%Account{}, %Account{}]

      iex> call_method("CashLens.Accounts", "Account", "get", [id])
      %Account{}
  """
  def call_method(target, method, args, raise_error_if_not_exists \\ true)
  def call_method(target, method, args, raise_error_if_not_exists) when is_atom(target) do
    call_method(Atom.to_string(target), method, args, raise_error_if_not_exists)
  end
  def call_method(target, method, args, raise_error_if_not_exists) do
    parts = String.split(target, ".")
    base_module = String.to_atom(Enum.join(Enum.drop(parts, -1), "."))
    method_target_name =
      case method do
        :list -> Enum.at(parts, -2)
        :to_str -> nil
        :get -> "#{List.last(parts)}!"
        _-> List.last(parts)
      end
    method_name =
    if method_target_name do
      Enum.join([method, method_target_name], "_")
      |> String.downcase
      |> String.to_atom
      else
      method
      end

    if Code.ensure_loaded?(base_module) and function_exported?(base_module, method_name, length(args)) do
      try do
        apply(base_module, method_name, args)
      rescue
        error ->
          {:error, Exception.message(error)}
      end
    else if raise_error_if_not_exists do
        raise "Method not found: #{inspect([base_module, method_name, length(args)])}"
      else
        Logger.info("Method not found: #{inspect([base_module, method_name, length(args)])}")
        nil
      end
    end
  end

  @doc """
  Formats changeset errors into a human-readable string.

  ## Parameters

  - `changeset` - The Ecto.Changeset containing errors

  ## Returns

  A string with formatted error messages
  """
  def format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{Utils.capitalize(field)}: #{message}" end)
    |> Enum.join(" - ")
  end

  @doc """
  Processes formatter functions for the CRUD interface.

  Converts formatter specifications into actual functions.

  ## Parameters

  - `formatter_map` - Map of field names to formatter specifications

  ## Returns

  A map of field names to formatter functions
  """
  def process_formatters(formatter_map) do
    formatter_map
    |> Enum.map(fn {k, v} ->
      v = case v do
        :capitalize -> &Utils.capitalize/1
        _ -> v
      end
      {k, v}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Generates form fields for the CRUD interface based on schema information.

  ## Parameters

  - `target` - The schema module to generate fields for
  - `formatter` - Map of field formatters
  - `current_user_id` - ID of the current user for filtering related data

  ## Returns

  A list of field specifications for the form
  """
  def generate_form_fields(target) do
    target.__schema__(:fields)
    |> Enum.filter(fn field -> field not in [:inserted_at, :updated_at, :id] end)
    |> Enum.map(fn field ->
      {type, label} =
        case target.__schema__(:type, field) do
          {:parameterized, {_, type}} ->
            {"select", Utils.capitalize_from_atom(field)}
          :id ->
            {"select", Utils.capitalize_from_atom(field) |> String.replace(" Id", "")}
          _ ->
            {"text", Utils.capitalize_from_atom(field)}
        end
      {field, type, label}
    end)
  end

  @doc """
  Processes a list of items by applying formatters to their fields.

  ## Parameters

  - `base_module` - The base module name
  - `plural_name` - The plural name of the entity
  - `current_user_id` - ID of the current user for filtering items
  - `fields` - List of field specifications
  - `formatter` - Map of field formatters

  ## Returns

  A list of items with formatted field values
  """
  def get_target_list(target, extra_args \\ []) do
    call_method(target, :list, extra_args)
  end

  def format_value(value, field, formatter) do
#    IO.inspect({"DEBUG", value, field, formatter})
    Map.get(formatter, field, fn x -> x end).(value)
  end

  def get_value(item, field, formatter) do
#    IO.inspect({"DEBUG", item, field, formatter})
    if String.ends_with?(Atom.to_string(field), "_id") do
      field =
        field
      |> Atom.to_string
      |> String.replace("_id", "")
      |> String.to_atom()
      value = Map.get(item, field)
      if value != nil do
        value_to_str = call_method_if_exists(value.__struct__, :to_str, [value]) || value.id
      end
    else
      Map.get(item, field)
      |> format_value(field, formatter)
    end
  end

  @doc """
  Renders a CRUD (Create, Read, Update, Delete) interface for a given schema.

  This component generates a complete UI for managing entities of the given schema,
  including a table of existing items and a button to create new items. It dynamically
  determines the fields to display based on the schema's fields and associations.

  ## Parameters

  - `assigns` - A map of assigns that must include:
    - `:target` - The schema module to generate the CRUD interface for
    - `:current_user` - The current user for filtering items
    - `:formatter` (optional) - A map of field formatters for customizing display

  ## Examples

      # In a LiveView template:
      crud(%{"target": CashLens.Accounts.Account, formatter: %{type: :capitalize}})
  """
  def crud(%{"target": target} = assigns) do
    formatter = Map.get(assigns, :formatter, %{})
    |> process_formatters()

    current_user_id = assigns.current_user.id

    {module_name, plural_name} = extract_module_info(assigns)

    fields = generate_form_fields(target)


    list = get_target_list(target, [current_user_id])

    assigns = assigns
      |> assign(target: target)
      |> assign(fields: fields)
      |> assign(list: list)
      |> assign(module_name: module_name)
      |> assign(plural_name: plural_name)
      |> assign(formatter: formatter)
    ~H"""
    <h1 class="text-2xl font-semibold">{@plural_name}</h1>
    <div class="bg-white shadow-md">
      <div class="px-4 py-5 sm:p-6">
        <div class="flex justify-between items-center">
          <h3 class="text-lg font-medium">{@plural_name} list</h3>
            <.button phx-click={show_modal("crud_modal")}>New {@module_name}</.button>
        </div>

        <.crud_modal {assigns} target={@target} formatter={@formatter} fields={@fields}/>
        <div class="mt-5">
          <%= if Enum.empty?(@list) do %>
            <p class="text-sm text-gray-500">No accounts yet. Create one to get started.</p>
          <% else %>
            <.table>
              <.table_header>
                <.table_row>
                  <%= for {field, _type, label} <- @fields do %>
                    <.table_head>{label}</.table_head>
                  <% end %>
                  <.table_head>Action</.table_head>
                </.table_row>
              </.table_header>
              <.table_body>
                <%= for item <- @list do %>
                  <.table_row>
                    <%= for {field, type, label} <- @fields do %>
                      <.table_cell>{get_value(item, field, @formatter)}</.table_cell>
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

  @doc """
  Renders a modal dialog for creating or editing items in the CRUD interface.

  This component is used by the `crud/1` component to provide a form for creating
  or editing items. It dynamically generates form fields based on the schema's fields.

  ## Parameters

  - `assigns` - A map of assigns that must include:
    - `:target` - The schema module to generate the form for
    - `:fields` - The fields to include in the form, as determined by the `crud/1` component
    - `:formatter` (optional) - A map of field formatters for customizing display

  ## Examples

      # In a LiveView template:
      crud_modal(%{"target": CashLens.Accounts.Account, fields: fields})
  """
  def crud_modal(%{"target": target, "fields": fields} = assigns) do

    changeset = target.changeset(struct(target, %{}), %{})

    required_fields = changeset.errors
      |> Enum.filter(fn {field, error} -> elem(error, 1) == [validation: :required] end)
    |> Enum.map(fn {field, error} -> field end)

    current_user_id = assigns.current_user.id

    formatter = Map.get(assigns, :formatter, %{})
    options =
      fields
      |> Enum.filter(fn {field, type, label} -> type == "select" end)
      |> Enum.map(fn {field, type, _label} ->
        options =
          case target.__schema__(:type, field) do
            {:parameterized, {_, type}} ->
              type.on_cast
              |> Map.keys
              |> Enum.map(fn v -> {format_value(v, field, formatter), v} end)
            :id ->
              model =
                target.__schema__(:associations)
                |> Enum.map(fn assoc_name ->
                  target.__schema__(:association, assoc_name)
                end)
                |> Enum.find(fn assoc ->
                    assoc.__struct__ == Ecto.Association.BelongsTo and assoc.owner_key == field
                end)
                |> Map.get(:related)

              get_target_list(model, if(field == :user_id, do: [], else: [current_user_id]))
              |> Enum.map(fn x -> {call_method_if_exists(model, :to_str, [x]) || x.name, x.id} end)
        end
          {field, options}
      end)
      |> Enum.into(%{})
    assigns =
      assigns
        |> assign(target: target)
        |> assign(changeset: changeset)
        |> assign(options: options)
        |> assign(formatter: formatter)
    ~H"""
          <.modal id="crud_modal">
            <.simple_form
            :let={f}
            for={@changeset}
            phx-submit="save"
            >
              <input type="hidden" name="target" value={@target} />
              <%= for {field, type, label} <- @fields do %>
                <%= case field do %>
                  <% _ -> %>
                    <.input label={label} field={f[field]} type={type} options={Map.get(@options, field, [])}/>
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
