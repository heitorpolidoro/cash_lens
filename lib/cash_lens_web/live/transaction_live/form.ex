defmodule CashLensWeb.TransactionLive.Form do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-xl mx-auto py-8">
      <.header>
        {@page_title}
        <:subtitle>Use este formulário para gerenciar os dados da transação.</:subtitle>
      </.header>

      <.form :let={f} for={@form} id="transaction-form" phx-change="validate" phx-submit="save" class="mt-8 space-y-6">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input field={f[:date]} type="date" label="Data" required />
          <.input field={f[:time]} type="time" label="Hora (opcional)" />
        </div>

        <.input field={f[:description]} type="text" label="Descrição" required placeholder="Ex: Supermercado, Aluguel..." />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input field={f[:amount]} type="number" label="Valor" step="0.01" required placeholder="0.00" />
          <.input field={f[:account_id]} type="select" label="Conta" options={Enum.map(@accounts, &{&1.name, &1.id})} required />
        </div>

        <.input field={f[:category_id]} type="select" label="Categoria (opcional)" options={Enum.map(@categories, &{CashLens.Categories.Category.full_name(&1), &1.id})} prompt="Pendente" />

        <div class="pt-4">
          <.button phx-disable-with="Salvando..." variant="primary" class="w-full">Salvar Transação</.button>
        </div>
      </.form>

      <div class="mt-4">
        <.link navigate={~p"/transactions"} class="text-sm font-semibold text-primary">
          <span class="hero-arrow-left size-3 mr-1"></span> Voltar para lista
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    categories = CashLens.Categories.list_categories()
    accounts = CashLens.Accounts.list_accounts()

    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> assign(:categories, categories)
     |> assign(:accounts, accounts)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    transaction = Transactions.get_transaction!(id)

    socket
    |> assign(:page_title, "Edit Transaction")
    |> assign(:transaction, transaction)
    |> assign(:form, to_form(Transactions.change_transaction(transaction)))
  end

  defp apply_action(socket, :new, _params) do
    transaction = %Transaction{}

    socket
    |> assign(:page_title, "New Transaction")
    |> assign(:transaction, transaction)
    |> assign(:form, to_form(Transactions.change_transaction(transaction)))
  end

  @impl true
  def handle_event("validate", %{"transaction" => transaction_params}, socket) do
    changeset = Transactions.change_transaction(socket.assigns.transaction, transaction_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"transaction" => transaction_params}, socket) do
    save_transaction(socket, socket.assigns.live_action, transaction_params)
  end

  defp save_transaction(socket, :edit, transaction_params) do
    case Transactions.update_transaction(socket.assigns.transaction, transaction_params) do
      {:ok, transaction} ->
        {:noreply,
         socket
         |> put_flash(:info, "Transaction updated successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, transaction))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_transaction(socket, :new, transaction_params) do
    case Transactions.create_transaction(transaction_params) do
      {:ok, transaction} ->
        {:noreply,
         socket
         |> put_flash(:info, "Transaction created successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, transaction))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _transaction), do: ~p"/transactions"
  defp return_path("show", transaction), do: ~p"/transactions/#{transaction}"
end
