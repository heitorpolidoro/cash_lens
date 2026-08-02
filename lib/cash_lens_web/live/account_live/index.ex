defmodule CashLensWeb.AccountLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Transactions

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Contas
        <:actions>
          <.link navigate={~p"/pluggy"}>
            <.button>
              <.icon name="hero-building-library" class="mr-1" /> Pluggy
            </.button>
          </.link>
          <.link navigate={~p"/accounts/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Conta
            </.button>
          </.link>
        </:actions>
      </.header>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th class="w-16 text-center">Ícone</th>
              <th>Nome</th>
              <th>Banco</th>
              <th class="text-right">Saldo Inicial</th>
              <th class="text-right">Saldo Atual</th>
              <th>Extrator</th>
              <th class="text-center">Importação?</th>
              <th class="text-center">Cartão de Crédito?</th>
              <th class="w-16"></th>
            </tr>
          </thead>
          <tbody id="accounts" phx-update="stream">
            <tr
              :for={{id, account} <- @streams.accounts}
              id={id}
              class={[
                "hover group border-b border-base-200 cursor-pointer",
                account.is_closed && "opacity-60"
              ]}
              phx-click={JS.navigate(~p"/transactions?account_id=#{account.id}&return_to=accounts")}
            >
              <td class="text-center py-4">
                <div class="avatar mx-auto">
                  <div class="w-8 rounded-full bg-base-300">
                    <%= if account.icon && account.icon != "" do %>
                      <img src={account.icon} />
                    <% else %>
                      <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content text-[10px] font-bold uppercase">
                        {String.slice(account.bank || account.name, 0..1)}
                      </div>
                    <% end %>
                  </div>
                </div>
              </td>
              <td class="font-bold">
                <span class="flex items-center gap-2">
                  {account.name}
                  <span
                    :if={account.is_closed}
                    class="badge badge-ghost badge-sm text-[9px] uppercase font-black tracking-wider opacity-60"
                  >
                    Encerrada
                  </span>
                </span>
              </td>
              <td class="opacity-70">{account.bank}</td>
              <td class="text-right font-mono opacity-60">
                {format_currency(account.balance)}
              </td>
              <td class="text-right">
                <div class="flex flex-col items-end gap-1">
                  <span class="font-mono font-black">
                    {format_currency(Map.get(@current_balances, account.id, account.balance))}
                  </span>
                  <button
                    :if={!account.is_credit_card}
                    type="button"
                    phx-click="open_update_balance_modal"
                    phx-value-id={account.id}
                    phx-click-stop
                    class="btn btn-ghost btn-xs opacity-0 group-hover:opacity-100 transition-opacity normal-case font-normal whitespace-nowrap"
                  >
                    <.icon name="hero-banknotes" class="size-3 mr-1" /> Atualizar com Rendimentos
                  </button>
                </div>
              </td>
              <td class="opacity-70">
                {translate_parser_type(account.parser_type)}
              </td>
              <td class="text-center">
                <%= if account.accepts_import do %>
                  <.icon name="hero-check-circle" class="size-5 text-success mx-auto" />
                <% else %>
                  <.icon name="hero-x-circle" class="size-5 text-base-300 mx-auto" />
                <% end %>
              </td>
              <td class="text-center">
                <%= if account.is_credit_card do %>
                  <.icon name="hero-check-circle" class="size-5 text-success mx-auto" />
                <% else %>
                  <.icon name="hero-x-circle" class="size-5 text-base-300 mx-auto" />
                <% end %>
              </td>
              <td class="text-right">
                <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                  <.link
                    navigate={~p"/accounts/#{account}/edit"}
                    class="btn btn-ghost btn-xs px-1"
                    phx-click-stop
                  >
                    <.icon name="hero-pencil" class="size-3" />
                  </.link>
                  <button
                    phx-click="confirm_delete"
                    phx-value-id={account.id}
                    phx-click-stop
                    class="btn btn-ghost btn-xs text-error px-1"
                  >
                    <.icon name="hero-trash" class="size-3" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Confirmation Modal -->
    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">Excluir Conta?</h2>
        <p class="text-base-content/60 mb-10">
          Deseja mesmo excluir esta conta? Esta ação removerá o registro permanentemente.
        </p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">
            Sim, Excluir
          </button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
            Cancelar
          </button>
        </div>
      </div>
    </.modal>

    <!-- Update Balance With Income Modal -->
    <.modal
      :if={@update_balance_modal}
      id="update-balance-modal"
      show
      on_cancel={JS.push("close_update_balance_modal")}
    >
      <div class="p-4">
        <h2 class="text-2xl font-black mb-2">Atualizar com Rendimentos</h2>
        <p class="text-base-content/60 mb-4">
          {@update_balance_modal.account.name}
        </p>
        <p class="text-sm mb-4">
          Saldo atual:
          <span class="font-mono font-bold">
            {format_currency(@update_balance_modal.current_balance)}
          </span>
        </p>
        <.form for={@update_balance_form} phx-submit="update_balance_with_income">
          <.input
            field={@update_balance_form[:new_balance]}
            type="number"
            step="any"
            label="Novo saldo"
          />
          <div class="flex gap-3 mt-6">
            <button type="submit" class="btn btn-primary flex-1 rounded-2xl">
              Confirmar
            </button>
            <button
              type="button"
              phx-click="close_update_balance_modal"
              class="btn btn-ghost flex-1 rounded-2xl"
            >
              Cancelar
            </button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Contas")
     |> assign(:confirm_modal, nil)
     |> assign(:update_balance_modal, nil)
     |> assign(:current_balances, current_balances_map())
     |> stream(:accounts, Accounts.list_accounts())}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, :confirm_modal, nil)}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:accounts, account)}
  end

  @impl true
  def handle_event("open_update_balance_modal", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    current_balance = Map.get(socket.assigns.current_balances, account.id, account.balance)

    {:noreply,
     socket
     |> assign(:update_balance_modal, %{account: account, current_balance: current_balance})
     |> assign(:update_balance_form, to_form(update_balance_changeset(%{}), as: :balance))}
  end

  @impl true
  def handle_event("close_update_balance_modal", _params, socket) do
    {:noreply, assign(socket, :update_balance_modal, nil)}
  end

  @impl true
  def handle_event("update_balance_with_income", %{"balance" => balance_params}, socket) do
    changeset = update_balance_changeset(balance_params)

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, %{new_balance: new_balance}} ->
        %{account: account, current_balance: current_balance} =
          socket.assigns.update_balance_modal

        diff = Decimal.sub(new_balance, current_balance)

        {:noreply, apply_balance_update(socket, account, diff)}

      {:error, changeset} ->
        {:noreply, assign(socket, :update_balance_form, to_form(changeset, as: :balance))}
    end
  end

  defp update_balance_changeset(params) do
    {%{}, %{new_balance: :decimal}}
    |> Ecto.Changeset.cast(params, [:new_balance])
    |> Ecto.Changeset.validate_required([:new_balance])
  end

  defp apply_balance_update(socket, account, diff) do
    if Decimal.equal?(diff, Decimal.new(0)) do
      socket
      |> assign(:update_balance_modal, nil)
      |> put_flash(:info, "Nenhuma diferença a registrar.")
    else
      account
      |> create_income_transaction(diff, Categories.get_category_by_slug("rendimento"))
      |> then(&apply_transaction_result(socket, &1))
    end
  end

  defp create_income_transaction(_account, _diff, nil), do: {:error, :category_not_found}

  defp create_income_transaction(account, diff, category) do
    Transactions.create_transaction(%{
      account_id: account.id,
      date: Date.utc_today(),
      description: "Rendimento",
      amount: diff,
      category_id: category.id
    })
  end

  defp apply_transaction_result(socket, {:ok, :duplicate}) do
    socket
    |> assign(:update_balance_modal, nil)
    |> put_flash(:error, "Já existe uma transação idêntica registrada.")
  end

  defp apply_transaction_result(socket, {:ok, _transaction}) do
    socket
    |> assign(:update_balance_modal, nil)
    |> assign(:current_balances, current_balances_map())
    |> put_flash(:success, "Rendimento registrado com sucesso.")
  end

  defp apply_transaction_result(socket, {:error, :category_not_found}) do
    socket
    |> assign(:update_balance_modal, nil)
    |> put_flash(:error, "Categoria Rendimento não encontrada.")
  end

  defp apply_transaction_result(socket, {:error, _changeset}) do
    socket
    |> assign(:update_balance_modal, nil)
    |> put_flash(:error, "Não foi possível registrar o rendimento.")
  end

  defp current_balances_map do
    Accounting.list_latest_balances()
    |> Map.new(fn b -> {b.account_id, b.final_balance} end)
  end
end
