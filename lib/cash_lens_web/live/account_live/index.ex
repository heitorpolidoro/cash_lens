defmodule CashLensWeb.AccountLive.Index do
  @moduledoc """
  The accounts and cards screen (CL-15).

  Bank accounts and credit cards are two visually distinct sections of cards
  rather than one table, and `/accounts/new` and `/accounts/:id/edit` mount
  this same LiveView so the settings form opens as an overlaid modal (still
  reachable as a deep link) instead of a separate page.
  """

  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Accounts.Account
  alias CashLens.Categories
  alias CashLens.Transactions
  alias CashLensWeb.AccountLive.FormComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b border-base-300">
        <div>
          <h1 class="text-2xl font-black tracking-tighter">Minhas Contas e Cartões</h1>
          <p class="text-xs text-base-content/60 mt-0.5">
            Gerencie suas contas bancárias, configurações de extrato e cartões de crédito.
          </p>
        </div>
        <div class="flex items-center gap-3">
          <form id="show-closed-form" phx-change="toggle_closed">
            <label class="flex items-center gap-2 text-xs font-bold cursor-pointer">
              <input type="hidden" name="show_closed" value="false" />
              <input
                type="checkbox"
                id="show-closed-toggle"
                name="show_closed"
                value="true"
                checked={@show_closed}
                class="checkbox checkbox-xs checkbox-primary"
              /> Mostrar contas encerradas
            </label>
          </form>
          <.link navigate={~p"/pluggy"}>
            <.button>
              <.icon name="hero-building-library" class="mr-1" /> Pluggy
            </.button>
          </.link>
          <.link patch={~p"/accounts/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Conta
            </.button>
          </.link>
        </div>
      </div>

      <section id="bank-accounts" class="space-y-4">
        <div class="flex items-center justify-between">
          <h2 class="text-xs font-black uppercase tracking-wider">
            Contas Bancárias e Carteiras ({length(@bank_accounts)})
          </h2>
          <span id="bank-accounts-total" class="text-xs font-bold text-base-content/60">
            Saldo Total:
            <strong class="text-primary font-black text-sm font-mono">
              {format_currency(@bank_total)}
            </strong>
          </span>
        </div>

        <p :if={@bank_accounts == []} class="text-sm text-base-content/50">
          Nenhuma conta bancária cadastrada.
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-5">
          <div
            :for={account <- @bank_accounts}
            id={"account-#{account.id}"}
            class={[
              "bg-base-100 rounded-2xl border border-base-300 p-5 shadow-sm flex flex-col justify-between hover:shadow-md transition",
              account.is_closed && "opacity-60"
            ]}
          >
            <div class="space-y-4">
              <div class="flex items-start justify-between gap-2">
                <div class="flex items-center gap-3">
                  <div
                    class="size-11 rounded-xl text-white flex items-center justify-center font-bold text-sm overflow-hidden bg-neutral"
                    style={account.color && "background-color: #{account.color}"}
                  >
                    <img
                      :if={filled?(account.icon)}
                      src={account.icon}
                      alt={account.name}
                      class="w-full h-full object-cover"
                    />
                    <span :if={!filled?(account.icon)} class="uppercase">
                      {initials(account)}
                    </span>
                  </div>
                  <div>
                    <h3 class="font-bold text-sm flex items-center gap-2">
                      {account.name}
                      <span
                        :if={account.is_closed}
                        class="badge badge-ghost badge-xs text-[9px] uppercase font-black tracking-wider"
                      >
                        Encerrada
                      </span>
                    </h3>
                    <span class="text-xs text-base-content/50">{account.bank}</span>
                  </div>
                </div>
                <.card_actions account={account} />
              </div>

              <div>
                <span class="text-[11px] font-semibold text-base-content/40 uppercase tracking-wider block">
                  Saldo Atual
                </span>
                <div class="text-2xl font-black font-mono">
                  {format_currency(current_balance(@current_balances, account))}
                </div>
                <span class="text-[11px] text-base-content/40">
                  Saldo inicial: {format_currency(account.balance)}
                </span>
              </div>

              <button
                :if={!account.is_closed}
                type="button"
                phx-click="open_update_balance_modal"
                phx-value-id={account.id}
                class="btn btn-ghost btn-xs normal-case font-normal"
              >
                <.icon name="hero-banknotes" class="size-3 mr-1" /> Rendimentos
              </button>
            </div>

            <div class="mt-4 pt-3 border-t border-base-200 flex items-center justify-between text-xs gap-2">
              <span class="text-base-content/50 truncate">
                Extrator: <strong>{translate_parser_type(account.parser_type)}</strong>
              </span>
              <.link
                navigate={~p"/transactions?account_id=#{account.id}&return_to=accounts"}
                class="font-bold text-primary hover:underline whitespace-nowrap"
              >
                Ver Extrato ➔
              </.link>
            </div>
          </div>
        </div>
      </section>

      <section id="credit-cards" class="space-y-4">
        <h2 class="text-xs font-black uppercase tracking-wider">
          Cartões de Crédito Cadastrados ({length(@credit_cards)})
        </h2>

        <p :if={@credit_cards == []} class="text-sm text-base-content/50">
          Nenhum cartão de crédito cadastrado.
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-5">
          <div
            :for={account <- @credit_cards}
            id={"account-#{account.id}"}
            class={[
              "rounded-2xl p-6 shadow-sm flex flex-col justify-between gap-5 text-white bg-neutral",
              account.is_closed && "opacity-60"
            ]}
            style={account.color && "background-color: #{account.color}"}
          >
            <div class="flex items-start justify-between gap-2">
              <div class="space-y-1">
                <div class="flex items-center gap-2">
                  <.icon name="hero-credit-card" class="size-4 opacity-70" />
                  <span class="text-xs font-black tracking-widest uppercase opacity-80">
                    {account.bank}
                  </span>
                </div>
                <h3 class="font-bold text-sm flex items-center gap-2">
                  {account.name}
                  <span
                    :if={account.is_closed}
                    class="badge badge-ghost badge-xs text-[9px] uppercase font-black tracking-wider text-base-content"
                  >
                    Encerrada
                  </span>
                </h3>
              </div>
              <.card_actions account={account} />
            </div>

            <div class="text-xs space-y-1">
              <p>
                Fecha dia <strong>{day_or_dash(account.closing_day)}</strong>
                · Vence dia <strong>{day_or_dash(account.due_day)}</strong>
              </p>
              <p class="opacity-80">
                Extrator: <strong>{translate_parser_type(account.parser_type)}</strong>
              </p>
            </div>

            <div class="pt-3 border-t border-white/20 flex items-center justify-end text-xs">
              <.link
                navigate={~p"/statements?account_id=#{account.id}"}
                class="font-bold hover:underline"
              >
                Ver Faturas ➔
              </.link>
            </div>
          </div>
        </div>
      </section>
    </div>

    <.live_component
      :if={@form_action}
      module={FormComponent}
      id="account-form-component"
      action={@form_action}
      account={@form_account}
    />

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

  attr :account, Account, required: true

  defp card_actions(assigns) do
    ~H"""
    <div class="flex items-center gap-1 shrink-0">
      <.link
        patch={~p"/accounts/#{@account.id}/edit"}
        class="btn btn-ghost btn-xs px-1"
        title="Editar configurações"
      >
        <.icon name="hero-pencil" class="size-3" />
      </.link>
      <button
        type="button"
        phx-click="toggle_archive"
        phx-value-id={@account.id}
        class="btn btn-ghost btn-xs px-1"
        title={if @account.is_closed, do: "Reativar conta", else: "Arquivar conta"}
        aria-label={if @account.is_closed, do: "Reativar conta", else: "Arquivar conta"}
      >
        <.icon
          name={if @account.is_closed, do: "hero-arrow-path", else: "hero-archive-box"}
          class="size-3"
        />
      </button>
      <button
        type="button"
        phx-click="confirm_delete"
        phx-value-id={@account.id}
        class="btn btn-ghost btn-xs px-1 text-error"
        title="Excluir conta"
        aria-label="Excluir conta"
      >
        <.icon name="hero-trash" class="size-3" />
      </button>
    </div>
    """
  end

  defp filled?(value), do: is_binary(value) and value != ""

  defp initials(account) do
    (account.bank || account.name || "")
    |> String.trim()
    |> String.slice(0..1)
  end

  defp day_or_dash(nil), do: "—"
  defp day_or_dash(day), do: day

  defp current_balance(current_balances, account) do
    Map.get(current_balances, account.id, account.balance)
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Contas")
     |> assign(:confirm_modal, nil)
     |> assign(:update_balance_modal, nil)
     |> assign(:show_closed, false)
     |> assign(:return_to, nil)
     |> assign(:form_action, nil)
     |> assign(:form_account, nil)
     |> load_accounts()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:return_to, params["return_to"])
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Nova Conta")
    |> assign(:form_action, :new)
    |> assign(:form_account, %Account{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Editar Conta")
    |> assign(:form_action, :edit)
    |> assign(:form_account, Accounts.get_account!(id))
  end

  defp apply_action(socket, _index, _params) do
    socket
    |> assign(:page_title, "Contas")
    |> assign(:form_action, nil)
    |> assign(:form_account, nil)
  end

  defp load_accounts(socket) do
    opts = [include_closed: socket.assigns.show_closed]
    current_balances = current_balances_map()
    bank_accounts = Accounts.list_bank_accounts(opts)

    socket
    |> assign(:current_balances, current_balances)
    |> assign(:bank_accounts, bank_accounts)
    |> assign(:credit_cards, Accounts.list_credit_cards(opts))
    |> assign(:bank_total, bank_total(bank_accounts, current_balances))
  end

  defp bank_total(bank_accounts, current_balances) do
    bank_accounts
    |> Enum.reject(& &1.is_closed)
    |> Enum.reduce(Decimal.new("0"), fn account, total ->
      Decimal.add(total, current_balance(current_balances, account) || Decimal.new("0"))
    end)
  end

  @impl true
  def handle_event("toggle_closed", params, socket) do
    {:noreply,
     socket
     |> assign(:show_closed, params["show_closed"] == "true")
     |> load_accounts()}
  end

  def handle_event("toggle_archive", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)

    {:ok, updated} = Accounts.update_account(account, %{is_closed: !account.is_closed})
    Accounting.rebuild_account_balances(updated.id)

    {:noreply,
     socket
     |> put_flash(:success, archive_flash(updated))
     |> load_accounts()}
  end

  def handle_event("close_account_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/accounts")}
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, :confirm_modal, nil)}

  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)

    {:noreply, socket |> assign(:confirm_modal, nil) |> load_accounts()}
  end

  def handle_event("open_update_balance_modal", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    current_balance = current_balance(socket.assigns.current_balances, account)

    {:noreply,
     socket
     |> assign(:update_balance_modal, %{account: account, current_balance: current_balance})
     |> assign(:update_balance_form, to_form(update_balance_changeset(%{}), as: :balance))}
  end

  def handle_event("close_update_balance_modal", _params, socket) do
    {:noreply, assign(socket, :update_balance_modal, nil)}
  end

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

  @impl true
  def handle_info({:account_saved, account, action}, socket) do
    {:noreply,
     socket
     |> put_flash(:success, saved_flash(action))
     |> load_accounts()
     |> return_from_form(account)}
  end

  defp saved_flash(:new), do: "Conta criada com sucesso"
  defp saved_flash(:edit), do: "Conta atualizada com sucesso"

  defp archive_flash(%Account{is_closed: true}), do: "Conta arquivada"
  defp archive_flash(%Account{}), do: "Conta reativada"

  defp return_from_form(socket, account) do
    case socket.assigns.return_to do
      "transactions" -> push_navigate(socket, to: ~p"/transactions")
      "show" -> push_navigate(socket, to: ~p"/accounts/#{account}")
      _ -> push_patch(socket, to: ~p"/accounts")
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
    |> load_accounts()
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
