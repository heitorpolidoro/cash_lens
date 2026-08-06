defmodule CashLensWeb.PluggyLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client
  alias CashLens.Pluggy.LivePreviewCache

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
        <:actions>
          <button type="button" phx-click="sync_all_items" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="size-4 mr-1" /> Sincronizar Tudo
          </button>
          <button type="button" phx-click="open_new_item_modal" class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4 mr-1" /> Novo Item
          </button>
        </:actions>
      </.header>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table table-zebra w-full text-sm">
          <thead>
            <tr>
              <th>Rótulo</th>
              <th>Conta Pluggy</th>
              <th>Tipo</th>
              <th class="text-right">Saldo Pluggy</th>
              <th>Conta cash_lens</th>
              <th class="w-24"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td class="font-bold">{row.item.label || row.item.item_id}</td>
              <td :if={row.link}>{row.link.pluggy_account_name}</td>
              <td :if={row.link}>{row.link.pluggy_account_type}</td>
              <td :if={row.link} class="text-right font-mono">
                {format_currency(row.link.pluggy_balance)}
              </td>
              <td :if={row.link}>
                <form phx-change="link_account">
                  <input type="hidden" name="link_id" value={row.link.id} />
                  <select name="account_id" class="select select-bordered select-sm">
                    <option value="">— selecione —</option>
                    <option
                      :for={account <- @accounts}
                      value={account.id}
                      selected={row.link.account_id == account.id}
                    >
                      {account.name} ({account.bank})
                    </option>
                  </select>
                </form>
              </td>
              <td :if={is_nil(row.link)} colspan="4" class="opacity-60 italic">
                Nenhuma conta sincronizada ainda
              </td>
              <td class="text-right whitespace-nowrap">
                <button
                  type="button"
                  phx-click="sync_accounts"
                  phx-value-item_id={row.item.id}
                  class="btn btn-ghost btn-xs"
                  title="Sincronizar contas"
                >
                  <.icon name="hero-arrow-path" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="confirm_delete_item"
                  phx-value-item_id={row.item.id}
                  class="btn btn-ghost btn-xs text-error"
                  title="Remover item"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="6" class="text-center opacity-60 italic py-8">
                Nenhum item cadastrado ainda.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <.modal
      :if={@show_new_item_modal}
      id="new-item-modal"
      show
      on_cancel={JS.push("close_new_item_modal")}
    >
      <div class="p-4">
        <h2 class="text-2xl font-black mb-6">Novo Item</h2>
        <.form for={@form} id="pluggy-item-form" phx-submit="create_item" class="space-y-4">
          <.input field={@form[:item_id]} type="text" label="Item ID" required />
          <.input field={@form[:label]} type="text" label="Rótulo (opcional)" />
          <div class="flex gap-3 mt-6">
            <button type="submit" class="btn btn-primary flex-1 rounded-2xl">
              Cadastrar
            </button>
            <button
              type="button"
              phx-click="close_new_item_modal"
              class="btn btn-ghost flex-1 rounded-2xl"
            >
              Cancelar
            </button>
          </div>
        </.form>
      </div>
    </.modal>

    <.modal
      :if={@confirm_modal}
      id="confirm-delete-item-modal"
      show
      on_cancel={JS.push("close_modal")}
    >
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">Remover Item?</h2>
        <p class="text-base-content/60 mb-10">
          Isso remove o item e todas as contas mapeadas a ele. As transações já importadas não são
          afetadas.
        </p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">
            Sim, Remover
          </button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
            Cancelar
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pluggy")
     |> assign(:form, to_form(%{"item_id" => "", "label" => ""}, as: :item))
     |> assign(:accounts, Accounts.list_accounts())
     |> assign(:confirm_modal, nil)
     |> assign(:show_new_item_modal, false)
     |> load_items()}
  end

  @impl true
  def handle_event("open_new_item_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_item_modal, true)}
  end

  @impl true
  def handle_event("close_new_item_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_item_modal, false)}
  end

  @impl true
  def handle_event("create_item", %{"item" => item_params}, socket) do
    case Pluggy.create_item(item_params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{"item_id" => "", "label" => ""}, as: :item))
         |> assign(:show_new_item_modal, false)
         |> load_items()
         |> put_flash(:success, "Item cadastrado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :item))}
    end
  end

  @impl true
  def handle_event("sync_accounts", %{"item_id" => item_id}, socket) do
    item = Pluggy.get_item!(item_id)
    req_options = Application.get_env(:cash_lens, :pluggy_req_options, [])

    with {:ok, client_id, client_secret} <- fetch_credentials(),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options),
         {:ok, _accounts} <- sync_item_accounts(item, api_key, req_options) do
      {:noreply, socket |> load_items() |> put_flash(:success, "Contas sincronizadas.")}
    else
      {:error, :missing_credentials} ->
        {:noreply,
         put_flash(socket, :error, "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao buscar contas no Pluggy.")}
    end
  end

  @impl true
  def handle_event("sync_all_items", _params, socket) do
    req_options = Application.get_env(:cash_lens, :pluggy_req_options, [])

    with {:ok, client_id, client_secret} <- fetch_credentials(),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options) do
      results =
        Enum.map(Pluggy.list_items(), fn item ->
          sync_item_accounts(item, api_key, req_options)
        end)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      failed_count = length(results) - ok_count

      message =
        "#{ok_count} item(ns) sincronizado(s)" <>
          if(failed_count > 0, do: ", #{failed_count} falharam.", else: ".")

      flash_kind = if failed_count > 0, do: :error, else: :success

      LivePreviewCache.refresh_now(live_preview_cache_server())

      {:noreply, socket |> load_items() |> put_flash(flash_kind, message)}
    else
      {:error, :missing_credentials} ->
        {:noreply,
         put_flash(socket, :error, "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao autenticar no Pluggy.")}
    end
  end

  @impl true
  def handle_event("link_account", %{"link_id" => link_id, "account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id
    link = CashLens.Repo.get!(CashLens.Pluggy.AccountLink, link_id)
    {:ok, _} = Pluggy.link_account(link, account_id)

    {:noreply, load_items(socket)}
  end

  @impl true
  def handle_event("confirm_delete_item", %{"item_id" => item_id}, socket) do
    confirm = %{action: JS.push("delete_item", value: %{item_id: item_id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_modal, nil)}
  end

  @impl true
  def handle_event("delete_item", %{"item_id" => item_id}, socket) do
    item = Pluggy.get_item!(item_id)
    {:ok, _} = Pluggy.delete_item(item)

    {:noreply,
     socket
     |> assign(:confirm_modal, nil)
     |> load_items()
     |> put_flash(:success, "Item removido.")}
  end

  # Which LivePreviewCache process to poke. Overridable so tests can point at
  # their own supervised instance (the cache is not started in `:test`).
  defp live_preview_cache_server,
    do: Application.get_env(:cash_lens, :pluggy_live_preview_cache_server, LivePreviewCache)

  defp fetch_credentials do
    client_id = System.get_env("PLUGGY_CLIENT_ID")
    client_secret = System.get_env("PLUGGY_CLIENT_SECRET")

    if is_binary(client_id) and is_binary(client_secret) do
      {:ok, client_id, client_secret}
    else
      {:error, :missing_credentials}
    end
  end

  defp sync_item_accounts(item, api_key, req_options) do
    with {:ok, accounts} <- Client.list_accounts(api_key, item.item_id, req_options) do
      Enum.each(accounts, fn account ->
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: account["id"],
          pluggy_account_name: account["name"],
          pluggy_account_type: account["type"],
          pluggy_balance: account["balance"]
        })
      end)

      {:ok, accounts}
    end
  end

  defp load_items(socket) do
    items = Pluggy.list_items()

    rows =
      Enum.flat_map(items, fn item ->
        case Pluggy.list_account_links_for_item(item.id) do
          [] -> [%{item: item, link: nil}]
          links -> Enum.map(links, fn link -> %{item: item, link: link} end)
        end
      end)

    assign(socket, :rows, rows)
  end
end
