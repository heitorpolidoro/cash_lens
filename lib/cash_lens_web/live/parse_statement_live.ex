defmodule CashLensWeb.ParseStatementLive do
  use CashLensWeb, :live_view
  import Ecto.Query

  alias CashLens.Parsers
  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Transactions
  alias CashLens.Reasons
  alias CashLens.Transactions.Transaction
  alias CashLens.Repo
  alias CashLens.ML.TransactionClassifier
  alias CashLens.Helper

  @text_reason_to_remove ["Pagamento de Boleto - "]

  @impl true
  def mount(_params, _session, socket) do
    statements = list_statement_files()
    parsers = Parsers.list_parsers()
    accounts = Accounts.list_accounts()
    categories = Categories.list_categories()

    #    special_categories = Categories.get_special_categories()

    {:ok,
     assign(socket,
       statements: statements,
       parsers: parsers,
       accounts: accounts,
       categories: categories,
       show_parser_modal: false,
       show_account_modal: false,
       show_new_category_modal: false,
       selected_statement: nil,
       selected_parser: nil,
       selected_account: nil,
       new_category_name: nil,
       new_category_transaction_index: nil,
       transactions: nil,
       retrain: false,
       special_categories: []
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_statement", %{"path" => path}, socket) do
    statement = Enum.find(socket.assigns.statements, &(&1.path == path))

    {:noreply,
     assign(socket,
       show_parser_modal: true,
       selected_statement: statement
     )}
  end

  @impl true
  def handle_event("close_modals", _, socket) do
    {:noreply,
     assign(socket,
       show_parser_modal: false,
       show_account_modal: false,
       show_new_category_modal: false
     )}
  end

  @impl true
  def handle_event("select_parser", %{"parser" => parser_module}, socket) do
    # Find the parser module
    _parser = Enum.find(socket.assigns.parsers, &(&1.module == parser_module))
    parser_module = String.to_existing_atom(parser_module)

    {:noreply,
     assign(socket,
       show_parser_modal: false,
       show_account_modal: true,
       selected_parser: parser_module
     )}
  end

  @impl true
  def handle_event("select_account", %{"account_id" => account_id} = _params, socket) do
    selected_account = Accounts.get_account!(String.to_integer(account_id))

    socket =
      socket
      |> assign(
        selected_account: selected_account,
        show_account_modal: false
      )

    handle_event("parse_file", nil, socket)
  end

  @impl true
  def handle_event("parse_file", _params, socket) do
    statement = socket.assigns.selected_statement
    parser_module = socket.assigns.selected_parser
    selected_account = socket.assigns.selected_account

    # Read file with latin1 encoding
    parsed_transactions =
      statement.path
      |> File.stream!()
      |> Stream.map(&:unicode.characters_to_binary(&1, :latin1))
      |> parser_module.parse
      |> Enum.filter(fn transaction -> !Reasons.should_ignore_reason(transaction.reason) end)
      |> Enum.map(fn transaction ->
        transaction
        |> Map.put(:account, selected_account)
        |> Map.put(:reason, clear_reason(transaction.reason))
        |> Transactions.set_category_with_prediction()
        |> Map.put(:refundable, false)

      end)

    # Check for duplicates in the database and within the parsed transactions
    transactions =
      parsed_transactions
      |> Enum.with_index()
      |> Enum.map(fn {transaction, index} ->
        # Check if transaction exists in database
        exists =
          Repo.exists?(
            from(t in Transaction,
              where:
                t.reason == ^transaction.reason and
                  t.datetime == ^transaction.datetime and
                  t.amount == ^transaction.amount
            )
          ) ||
            Enum.with_index(parsed_transactions)
            |> Enum.any?(fn {t, i} ->
              i != index &&
                t.reason == transaction.reason &&
                t.datetime == transaction.datetime &&
                t.amount == transaction.amount
            end)

        # Mark as existing if it exists in DB or is duplicated in the list
        Map.put(transaction, :exists, exists)
      end)

    {:noreply,
     assign(socket,
       show_parser_modal: false,
       transactions: transactions
     )}
  end

  @impl true
  def handle_event(
        "select_category",
        %{"category_select" => category_str, "index" => index_str},
        socket
      ) do
    # Parse the value to get category_id and index
    index = String.to_integer(index_str)

    socket =
      case category_str do
        "new" ->
          # Show the new category modal
          assign(socket,
            show_new_category_modal: true,
            new_category_transaction_index: index,
            new_category_name: ""
          )

        _ ->
          updated_transactions =
            socket.assigns.transactions
            |> List.update_at(index, fn transaction ->
              %{transaction | category_id: String.to_integer(category_str)}
            end)

          assign(socket, transactions: updated_transactions)
      end

    {:noreply, assign(socket, retrain: true)}
  end

  @impl true
  def handle_event("update_new_category_name", %{"value" => name}, socket) do
    {:noreply, assign(socket, new_category_name: name)}
  end

  @impl true
  def handle_event(
        "create_category",
        %{"category_name" => name, "category_fixed" => fixed},
        socket
      ) do
    # Create a new category
    case Categories.create_category(%{name: name, fixed: fixed}) do
      {:ok, category} ->
        # Update the transaction with the new category
        index = socket.assigns.new_category_transaction_index

        updated_transactions =
          socket.assigns.transactions
          |> List.update_at(index, fn transaction ->
            %{transaction | category: category}
          end)

        # Update the categories list
        updated_categories = [category | socket.assigns.categories]

        {:noreply,
         assign(socket,
           transactions: updated_transactions,
           categories: updated_categories,
           show_new_category_modal: false,
           retrain: true
         )}

      {:error, _changeset} ->
        # Show an error message
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create category. Name may already be taken.")
         |> assign(show_new_category_modal: false)}
    end
  end

  @impl true
  def handle_event(
        "toggle_refundable",
        %{"refundable_checkbox" => refundable, "index" => index_str},
        socket
      ) do
    index = String.to_integer(index_str)

    updated_transactions =
      socket.assigns.transactions
      |> List.update_at(index, fn transaction ->
        %{transaction | refundable: refundable == "true"}
      end)

    {:noreply, assign(socket, transactions: updated_transactions)}
  end

  @impl true
  def handle_event("save_transaction", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    transactions = socket.assigns.transactions

    transaction =
      transactions
      |> Enum.at(index)

    transaction_attrs =
      transaction
      |> Map.take([:datetime, :amount, :reason, :refundable, :category_id])
      |> Map.put(:account_id, transaction.account.id)
      |> Map.put(:category_id, transaction.category_id || transaction.category.id)
      |> Map.put(:category, transaction.category || Categories.get_category!(transaction.category_id))

    case Transactions.create_transaction(transaction_attrs) do
      {:ok, _transaction} ->
        transactions =
          if socket.assigns.retrain do
            TransactionClassifier.train_model()
            Transactions.set_category_with_prediction(transactions)
          else
            transactions
          end
          |> List.delete_at(index)

        {
          :noreply,
          socket
          |> put_flash(
            :info,
            "Transaction saved successfully" <>
              if(socket.assigns.retrain, do: ". Retrained", else: "")
          )
          |> assign(transactions: transactions, retrain: false)
        }

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_errors_to_string(changeset))}
    end
  end

  @impl true
  def handle_event("ignore_transaction", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    {
      :noreply,
      socket
      |> put_flash(:info, "Transaction ignored successfully")
      |> assign(transactions: List.delete_at(socket.assigns.transactions, index))
    }
  end

  @impl true
  def handle_event("ignore_reason", %{"reason" => reason, "index" => index_str}, socket) do
    case Reasons.create_reason(%{reason: reason, ignore: true}) do
      {:ok, _reason} ->
        index = String.to_integer(index_str)

        {
          :noreply,
          socket
          |> assign(transactions: List.delete_at(socket.assigns.transactions, index))
          |> put_flash(:info, "Reason '#{reason}' added to ignore list")
        }

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_errors_to_string(changeset))}
    end
  end

  # Get all errors as a single string
  def changeset_errors_to_string(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "#{humanize_field(field)}: #{Enum.join(errors, ", ")}"
    end)
    |> Enum.join("; ")
  end

  defp humanize_field(field) do
    field
    |> Atom.to_string()
    |> String.trim_trailing("_id")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp list_statement_files do
    Path.wildcard("statements/*.{csv,ofx,qif}")
    |> Enum.map(fn path ->
      %{
        path: path,
        filename: Path.basename(path),
        size: File.stat!(path).size,
        last_modified: File.stat!(path).mtime |> NaiveDateTime.from_erl!()
      }
    end)
  end

  defp clear_reason(reason) do
    @text_reason_to_remove
    |> Enum.reduce(reason, fn reason_to_remove, acc ->
      String.replace(acc, reason_to_remove, "")
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto py-8 px-4 sm:px-6 lg:px-8">
      <h1 class="text-2xl font-semibold text-zinc-900 mb-6">Parse Statement</h1>

      <div class="bg-white shadow rounded-lg p-6">
        <p class="mb-4 text-zinc-600">
          Select a statement file to import transactions.
        </p>

        <div class="mt-6">
          <%= if @statements == [] do %>
            <div class="text-center py-8 text-zinc-500">
              <p>No statement files found in the statements folder.</p>
            </div>
          <% else %>
            <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
              <table class="min-w-full divide-y divide-zinc-300">
                <thead class="bg-zinc-50">
                  <tr>
                    <th
                      scope="col"
                      class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-zinc-900 sm:pl-6"
                    >
                      Filename
                    </th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-zinc-900">
                      Size
                    </th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-zinc-900">
                      Last Modified
                    </th>
                    <th scope="col" class="relative py-3.5 pl-3 pr-4 sm:pr-6">
                      <span class="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-200 bg-white">
                  <%= for statement <- @statements do %>
                    <tr>
                      <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-zinc-900 sm:pl-6">
                        {statement.filename}
                      </td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-zinc-500">
                        {format_size(statement.size)}
                      </td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-zinc-500">
                        {Helper.format_date(statement.last_modified)}
                      </td>
                      <td class="relative whitespace-nowrap py-4 pl-3 pr-4 text-right text-sm font-medium sm:pr-6">
                        <button
                          phx-click="select_statement"
                          phx-value-path={statement.path}
                          class="text-indigo-600 hover:text-indigo-900"
                        >
                          Parse
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
      <.transactions_table
        transactions={@transactions}
        categories={@categories}
        special_categories={@special_categories}
      />

      <.parser_modal
        show_parser_modal={@show_parser_modal}
        selected_statement={@selected_statement}
        parsers={@parsers}
      />
      <.account_modal
        show_account_modal={@show_account_modal}
        selected_statement={@selected_statement}
        accounts={@accounts}
      />
      <.new_category_modal
        show_new_category_modal={@show_new_category_modal}
        new_category_name={@new_category_name}
      />
    </div>
    """
  end

  def parser_modal(assigns) do
    ~H"""
    <%= if @show_parser_modal do %>
      <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900">Select Parser</h3>
            <button phx-click="close_modals" class="text-gray-400 hover:text-gray-500">
              <span class="sr-only">Close</span>
              <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <p class="mb-4 text-sm text-gray-500">
            Select a parser for {@selected_statement && @selected_statement.filename}
          </p>

          <div class="space-y-2">
            <%= for parser <- @parsers do %>
              <button
                phx-click="select_parser"
                phx-value-parser={parser.module}
                class="w-full text-left px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
              >
                {parser.name}
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  def account_modal(assigns) do
    ~H"""
    <%= if @show_account_modal do %>
      <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900">Select Account</h3>
            <button phx-click="close_modals" class="text-gray-400 hover:text-gray-500">
              <span class="sr-only">Close</span>
              <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <p class="mb-4 text-sm text-gray-500">
            Select a Account for {@selected_statement && @selected_statement.filename}
          </p>

          <div class="space-y-2">
            <%= for account <- @accounts do %>
              <button
                phx-click="select_account"
                phx-value-account_id={account.id}
                class="w-full text-left px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
              >
                {Accounts.to_str(account)}
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  def new_category_modal(assigns) do
    ~H"""
    <%= if @show_new_category_modal do %>
      <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900">Create New Category</h3>
            <button phx-click="close_modals" class="text-gray-400 hover:text-gray-500">
              <span class="sr-only">Close</span>
              <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <form phx-submit="create_category">
            <div class="mb-4">
              <label for="category_name" class="block text-sm font-medium text-gray-700">
                Category Name
              </label>
              <.input name="category_name" value={nil} type="text" label="Name" />
              <.input name="category_fixed" value={false} type="checkbox" label="Fixed" />
            </div>
            <div class="flex justify-end">
              <button type="submit">
                Create
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  def transactions_table(assigns) do
    ~H"""
    <%= if @transactions do %>
      <div class="bg-white shadow rounded-lg p-6">
        <.table
          id="transactions"
          rows={Enum.with_index(@transactions)}
          row_class={fn {t, _index} -> if t.exists, do: "bg-yellow-100", else: "" end}
        >
          <:col :let={{_transaction, index}} label="Save">
            <button phx-click="save_transaction" phx-value-index={index} type="button">
              <.icon name="hero-check" class="h-5 w-5 text-green-800" />
            </button>
            <button phx-click="ignore_transaction" phx-value-index={index} type="button">
              <.icon name="hero-x-mark" class="h-5 w-5 text-red-800" />
            </button>
          </:col>
          <:col :let={{transaction, _index}} label="Date">
            {Calendar.strftime(transaction.datetime, "%d/%m/%Y %H:%M")}
          </:col>
          <:col :let={{transaction, _index}} label="Account">
            {(transaction.account && Accounts.to_str(transaction.account)) || "-"}
          </:col>
          <:col :let={{transaction, _index}} label="Value">
            <div class="text-right">
              <span class={
                cond do
                  transaction.amount > 0 -> "text-blue-600"
                  transaction.amount < 0 -> "text-red-600"
                  true -> ""
                end
              }>
                {Helper.format_currency(transaction.amount)}
              </span>
            </div>
          </:col>
          <:col :let={{transaction, index}} label="Reason">
            <button
              phx-click="ignore_reason"
              phx-value-reason={transaction.reason}
              phx-value-index={index}
              type="button"
            >
              <.icon name="hero-no-symbol" class="h-5 w-5 text-red-600" />
            </button>
            {transaction.reason || "-"}
          </:col>
          <:col :let={{transaction, index}} label="Category">
            <form phx-change="select_category" phx-value-index={index}>
              <select name="category_select">
                <option value="" disabled selected={is_nil(transaction.category)}>
                  -- Select Category --
                </option>
                <%= for category <- @categories do %>
                  <option
                    value={category.id}
                    selected={transaction.category && transaction.category.id == category.id}
                  >
                    {category.name}
                  </option>
                <% end %>
                <option value="new">+ Create New Category</option>
              </select>
            </form>
          </:col>
          <:col :let={{transaction, index}} label="Refundable">
            <form phx-change="toggle_refundable" phx-value-index={index}>
              <.input type="checkbox" name="refundable_checkbox" checked={transaction.refundable} />
            </form>
          </:col>
        </.table>
      </div>
    <% end %>
    """
  end

  defp format_size(size) when size < 1024, do: "#{size} B"
  defp format_size(size) when size < 1024 * 1024, do: "#{Float.round(size / 1024, 2)} KB"
  defp format_size(size), do: "#{Float.round(size / (1024 * 1024), 2)} MB"

end
