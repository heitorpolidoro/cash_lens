defmodule CashLensWeb.AccountLive.FormComponent do
  @moduledoc """
  The account settings form, rendered as a modal overlaid on `/accounts` for
  both `/accounts/new` and `/accounts/:id/edit` (CL-15).

  The colour presets are the institutional colours of the banks this app is
  used with: clicking one only writes the hex into the `color` field, so the
  user is still free to type any other value.

  The icon is a plain URL string (never an upload): the circular preview next
  to the field reacts to the regular `phx-change` validate cycle, so it follows
  whatever the user types without any extra event.
  """

  use CashLensWeb, :live_component

  alias CashLens.Accounting
  alias CashLens.Accounts

  @parser_options [
    {"Bradesco (CSV)", "bradesco_csv"},
    {"Bradesco Cartão (PDF)", "bradesco_cartao_pdf"},
    {"Mercado Pago Cartão (PDF)", "mercadopago_cartao_pdf"},
    {"Banco do Brasil (CSV)", "bb_csv"},
    {"Mercado Pago (CSV)", "mercado_pago_csv"},
    {"Ourocard (OFX)", "ourocard_ofx"},
    {"Sem Parar (PDF)", "sem_parar_pdf"},
    {"OFX Padrão", "standard_ofx"}
  ]

  @color_presets [
    {"Nubank", "#820ad1"},
    {"Itaú", "#ec7000"},
    {"Banco do Brasil", "#fae128"},
    {"Mercado Pago", "#009ee3"},
    {"Inter", "#ff7a00"},
    {"Bradesco", "#cc092f"},
    {"Santander", "#ec0000"},
    {"Caixa", "#0070af"},
    {"C6 Bank", "#242424"},
    {"Neutro", "#64748b"}
  ]

  @impl true
  def update(%{account: account, action: action} = assigns, socket) do
    current_balance = current_balance(account, action)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:parser_options, @parser_options)
     |> assign(:color_presets, @color_presets)
     |> assign(:current_balance_on_load, current_balance)
     |> assign(:form, to_form(Accounts.change_account(account, %{})))
     |> assign(:current_balance_value, current_balance)}
  end

  defp current_balance(_account, :new), do: nil

  defp current_balance(account, :edit) do
    case Accounting.get_latest_balance_for_account(account.id) do
      nil -> account.balance
      balance -> balance.final_balance
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="account-form-modal"
      class="modal modal-open"
      phx-window-keydown="close_account_modal"
      phx-key="escape"
    >
      <div class="modal-box max-w-xl p-0 bg-base-100 border border-base-300 rounded-3xl shadow-2xl">
        <div class="px-6 py-4 border-b border-base-200 flex items-center justify-between bg-base-200/40">
          <div>
            <h3 class="text-sm font-black uppercase tracking-tighter">{modal_title(@action)}</h3>
            <p class="text-xs text-base-content/50">
              Dados da conta, identidade visual e regras de importação.
            </p>
          </div>
          <button
            id="account-form-modal-close"
            type="button"
            phx-click="close_account_modal"
            class="btn btn-sm btn-circle btn-ghost"
            aria-label="Fechar"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          for={@form}
          id="account-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          class="px-6 py-5 max-h-[70vh] overflow-y-auto"
        >
          <.input field={@form[:name]} type="text" label="Nome da Conta" />
          <.input field={@form[:bank]} type="text" label="Instituição / Banco" />

          <div class="mb-4">
            <span class="label-text font-bold">Cor do Card</span>
            <div class="flex flex-wrap gap-2 mt-2 mb-2">
              <button
                :for={{name, hex} <- @color_presets}
                type="button"
                title={name}
                aria-label={name}
                phx-click="pick_color"
                phx-value-color={hex}
                phx-target={@myself}
                class={[
                  "size-7 rounded-full border-2 transition",
                  if(@form[:color].value == hex,
                    do: "border-base-content scale-110",
                    else: "border-base-300"
                  )
                ]}
                style={"background-color: #{hex}"}
              >
              </button>
            </div>
            <.input field={@form[:color]} type="text" placeholder="#000000" />
          </div>

          <.input
            field={@form[:parser_type]}
            type="select"
            label="Extrator (Parser)"
            options={@parser_options}
            prompt="Selecione um extrator"
          />
          <p class="text-[10px] opacity-50 -mt-3 mb-4 px-1">
            Define como os arquivos de extrato/fatura desta conta são lidos na importação.
          </p>

          <div class="flex items-end gap-3 mb-1">
            <div
              id="account-icon-preview"
              class="size-11 shrink-0 mb-4 rounded-full border border-base-300 bg-base-200 flex items-center justify-center overflow-hidden"
            >
              <img
                :if={filled?(@form[:icon].value)}
                src={@form[:icon].value}
                alt="Prévia do ícone"
                class="w-full h-full object-cover"
              />
              <.icon :if={!filled?(@form[:icon].value)} name="hero-photo" class="size-5 opacity-20" />
            </div>
            <div class="flex-1">
              <.input field={@form[:icon]} type="text" label="Ícone da Conta (URL)" />
            </div>
          </div>
          <p class="text-[10px] opacity-50 mb-4 px-1">
            Opcional. Cole a URL da logo da instituição; a prévia é atualizada ao digitar.
          </p>

          <.input field={@form[:balance]} type="number" label="Saldo Inicial (Base)" step="any" />

          <div :if={@action == :edit} class="mb-4">
            <.input
              field={@form[:current_balance]}
              type="number"
              label="Saldo Atual (Ajustar)"
              step="any"
              value={@current_balance_value}
              phx-debounce="blur"
            />
            <p class="text-[10px] opacity-50 px-1">
              Ajustar este valor irá alterar automaticamente o Saldo Inicial para corresponder.
            </p>
          </div>

          <div class="flex flex-wrap gap-6 py-2">
            <.input
              field={@form[:accepts_import]}
              type="checkbox"
              label="Aceita importação de extratos?"
            />
            <.input field={@form[:is_closed]} type="checkbox" label="Conta encerrada?" />
            <.input
              field={@form[:is_credit_card]}
              type="checkbox"
              label="Esta conta é um Cartão de Crédito"
            />
          </div>

          <div :if={credit_card?(@form)} class="space-y-2 border-t border-base-200 pt-4">
            <h4 class="text-xs font-black uppercase tracking-wider opacity-40">Ciclo de Fatura</h4>
            <div class="flex flex-wrap items-end gap-4">
              <.input
                field={@form[:closing_day]}
                type="number"
                label="Dia de fechamento"
                min="1"
                max="31"
              />
              <.input
                field={@form[:due_day]}
                type="number"
                label="Dia de vencimento"
                min="1"
                max="31"
              />
              <button
                type="button"
                class="btn btn-xs btn-outline mb-4"
                phx-click="estimate_cycle"
                phx-target={@myself}
              >
                Estimar do histórico
              </button>
            </div>
          </div>

          <div class="flex flex-col sm:flex-row gap-3 pt-4 border-t border-base-200">
            <.button phx-disable-with="Salvando..." variant="primary" class="flex-1">
              Salvar Conta
            </.button>
            <button
              type="button"
              phx-click="close_account_modal"
              class="btn btn-ghost flex-1 rounded-2xl"
            >
              Cancelar
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/40 backdrop-blur-sm" phx-click="close_account_modal"></div>
    </div>
    """
  end

  defp modal_title(:new), do: "Nova Conta / Cartão"
  defp modal_title(:edit), do: "Editar Conta"

  defp filled?(value), do: is_binary(value) and value != ""

  defp credit_card?(form), do: form[:is_credit_card].value in [true, "true"]

  @impl true
  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset =
      socket.assigns.account
      |> Accounts.change_account(account_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:current_balance_value, account_params["current_balance"])}
  end

  def handle_event("pick_color", %{"color" => color}, socket) do
    changeset = Ecto.Changeset.put_change(socket.assigns.form.source, :color, color)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("estimate_cycle", _params, socket) do
    account = socket.assigns.account

    if account.id do
      estimate = CashLens.CreditCards.estimate_cycle(account)

      changeset =
        socket.assigns.form.source
        |> Ecto.Changeset.put_change(:closing_day, estimate.closing_day)
        |> Ecto.Changeset.put_change(:due_day, estimate.due_day)

      {:noreply, assign(socket, :form, to_form(changeset))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"account" => account_params}, socket) do
    save_account(socket, socket.assigns.action, account_params)
  end

  defp save_account(socket, :edit, account_params) do
    account = socket.assigns.account
    adjusted_params = adjust_initial_balance(socket, account_params)

    case Accounts.update_account(account, adjusted_params) do
      {:ok, updated} ->
        maybe_rebuild_balances(account, updated)
        send(self(), {:account_saved, updated, :edit})
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_account(socket, :new, account_params) do
    case Accounts.create_account(account_params) do
      {:ok, account} ->
        # Initialize the monthly balance record for the new account.
        Accounting.rebuild_account_balances(account.id)
        send(self(), {:account_saved, account, :new})
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # The user edits the *current* balance, but only the initial balance is
  # stored: the difference is applied to it so the chained balances land on the
  # number that was typed.
  defp adjust_initial_balance(socket, account_params) do
    with typed when is_binary(typed) and typed != "" <- account_params["current_balance"],
         original when not is_nil(original) <- socket.assigns.current_balance_on_load,
         new_current = Decimal.new(typed),
         false <- Decimal.equal?(new_current, original) do
      delta = Decimal.sub(new_current, original)
      original_initial = socket.assigns.account.balance || Decimal.new("0")

      Map.put(account_params, "balance", Decimal.add(original_initial, delta))
    else
      _ -> account_params
    end
  end

  defp maybe_rebuild_balances(previous, updated) do
    if not Decimal.equal?(previous.balance, updated.balance) or
         previous.is_closed != updated.is_closed do
      Accounting.rebuild_account_balances(updated.id)
    end
  end
end
