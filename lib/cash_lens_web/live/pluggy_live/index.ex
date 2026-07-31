defmodule CashLensWeb.PluggyLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Pluggy
        <:subtitle>
          Cadastre um itemId de uma conexão Pluggy e associe cada conta dela a uma conta do
          cash_lens. A importação das transações roda pelo botão "Importar do Pluggy" na tela de
          Transações.
        </:subtitle>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <h2 class="text-sm font-black uppercase opacity-50 mb-4">Novo Item</h2>
              <.form for={@form} id="pluggy-item-form" phx-submit="create_item" class="space-y-4">
                <.input field={@form[:item_id]} type="text" label="Item ID" required />
                <.input field={@form[:label]} type="text" label="Rótulo (opcional)" />
                <button type="submit" class="btn btn-primary w-full rounded-xl">
                  Cadastrar
                </button>
              </.form>
            </div>
          </div>
        </div>

        <div class="lg:col-span-2 space-y-6">
          <div :for={item <- @items} class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="font-bold">{item.label || item.item_id}</h2>
                <button
                  type="button"
                  phx-click="sync_accounts"
                  phx-value-item_id={item.id}
                  class="btn btn-outline btn-sm"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Sincronizar contas
                </button>
              </div>

              <table :if={@links_by_item[item.id]} class="table table-sm w-full">
                <thead>
                  <tr>
                    <th>Conta Pluggy</th>
                    <th>Tipo</th>
                    <th>Conta cash_lens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={link <- @links_by_item[item.id]}>
                    <td>{link.pluggy_account_name}</td>
                    <td>{link.pluggy_account_type}</td>
                    <td>
                      <form phx-change="link_account">
                        <input type="hidden" name="link_id" value={link.id} />
                        <select name="account_id" class="select select-bordered select-sm">
                          <option value="">— selecione —</option>
                          <option
                            :for={account <- @accounts}
                            value={account.id}
                            selected={link.account_id == account.id}
                          >
                            {account.name} ({account.bank})
                          </option>
                        </select>
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pluggy")
     |> assign(:form, to_form(%{"item_id" => "", "label" => ""}, as: :item))
     |> assign(:accounts, Accounts.list_accounts())
     |> load_items()}
  end

  @impl true
  def handle_event("create_item", %{"item" => item_params}, socket) do
    case Pluggy.create_item(item_params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{"item_id" => "", "label" => ""}, as: :item))
         |> load_items()
         |> put_flash(:success, "Item cadastrado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :item))}
    end
  end

  @impl true
  def handle_event("sync_accounts", %{"item_id" => item_id}, socket) do
    item = Pluggy.get_item!(item_id)
    client_id = System.get_env("PLUGGY_CLIENT_ID")
    client_secret = System.get_env("PLUGGY_CLIENT_SECRET")
    req_options = Application.get_env(:cash_lens, :pluggy_req_options, [])

    with true <- is_binary(client_id) and is_binary(client_secret),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options),
         {:ok, accounts} <- Client.list_accounts(api_key, item.item_id, req_options) do
      Enum.each(accounts, fn account ->
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: account["id"],
          pluggy_account_name: account["name"],
          pluggy_account_type: account["type"]
        })
      end)

      {:noreply, socket |> load_items() |> put_flash(:success, "Contas sincronizadas.")}
    else
      false ->
        {:noreply,
         put_flash(socket, :error, "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao buscar contas no Pluggy.")}
    end
  end

  @impl true
  def handle_event("link_account", %{"link_id" => link_id, "account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id
    link = CashLens.Repo.get!(CashLens.Pluggy.AccountLink, link_id)
    {:ok, _} = Pluggy.link_account(link, account_id)

    {:noreply, load_items(socket)}
  end

  defp load_items(socket) do
    items = Pluggy.list_items()

    links_by_item =
      Map.new(items, fn item -> {item.id, Pluggy.list_account_links_for_item(item.id)} end)

    socket
    |> assign(:items, items)
    |> assign(:links_by_item, links_by_item)
  end
end
