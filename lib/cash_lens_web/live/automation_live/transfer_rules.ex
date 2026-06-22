defmodule CashLensWeb.AutomationLive.TransferRules do
  use CashLensWeb, :live_view
  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Transactions.TransferRule

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Regras de Transferência
        <:subtitle>
          Defina regras que criam automaticamente transações espelhadas em uma conta de destino
          quando uma transação com descrição correspondente é encontrada na conta de origem.
        </:subtitle>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <!-- Registration / Edit Form -->
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <h2 class="text-sm font-black uppercase opacity-50 mb-4">
                {if @current_rule, do: "Editar Regra", else: "Nova Regra"}
              </h2>
              <.form
                for={@form}
                id="transfer-rule-form"
                phx-submit="save"
                phx-change="validate"
                class="space-y-4"
              >
                <.input
                  field={@form[:label]}
                  type="text"
                  label="Rótulo (opcional)"
                  placeholder="ex. Transferência para Poupança"
                />
                <.input
                  field={@form[:description_patterns_raw]}
                  type="text"
                  label="Padrões de Descrição (separados por vírgula)"
                  placeholder="ex. Transfer para Poupança, SAVINGS XFER"
                  required
                />
                <.input
                  field={@form[:source_account_id]}
                  type="select"
                  label="Conta de Origem"
                  options={account_options(@accounts)}
                  prompt="Selecione a conta de origem"
                  required
                />
                <.input
                  field={@form[:destination_account_id]}
                  type="select"
                  label="Conta de Destino"
                  options={account_options(@accounts)}
                  prompt="Selecione a conta de destino"
                  required
                />
                <.input
                  field={@form[:create_mirror]}
                  type="checkbox"
                  label="Criar transação espelhada na conta de destino"
                />
                <div class="pt-2 flex gap-2">
                  <button
                    type="submit"
                    class="btn btn-primary flex-1 rounded-xl"
                    phx-disable-with="Salvando..."
                  >
                    Salvar Regra
                  </button>
                  <button
                    :if={@current_rule}
                    type="button"
                    phx-click="cancel_edit"
                    class="btn btn-ghost rounded-xl"
                  >
                    Cancelar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
        
    <!-- Rules Table -->
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden">
            <div class="card-body p-0">
              <table class="table table-zebra w-full text-xs">
                <thead class="bg-base-200/50">
                  <tr>
                    <th>Rótulo</th>
                    <th>Padrões</th>
                    <th>Conta de Origem</th>
                    <th>Conta de Destino</th>
                    <th>Espelhar?</th>
                    <th class="w-20"></th>
                  </tr>
                </thead>
                <tbody id="transfer-rules" phx-update="stream">
                  <tr :for={{id, rule} <- @streams.transfer_rules} id={id} class="hover group">
                    <td class="font-semibold">{rule.label || "-"}</td>
                    <td class="font-mono text-primary">
                      {Enum.join(rule.description_patterns, ", ")}
                    </td>
                    <td class="opacity-70">{rule.source_account.name}</td>
                    <td class="opacity-70">{rule.destination_account.name}</td>
                    <td>
                      <.icon
                        :if={rule.create_mirror}
                        name="hero-check-circle"
                        class="size-5 text-success"
                      />
                      <.icon
                        :if={!rule.create_mirror}
                        name="hero-x-circle"
                        class="size-5 text-base-300"
                      />
                    </td>
                    <td class="text-right pr-4">
                      <div class="flex gap-1 justify-end opacity-0 group-hover:opacity-100 transition-opacity">
                        <button
                          phx-click="edit"
                          phx-value-id={rule.id}
                          class="btn btn-ghost btn-xs text-info"
                        >
                          <.icon name="hero-pencil" class="size-4" />
                        </button>
                        <button
                          phx-click="delete"
                          phx-value-id={rule.id}
                          data-confirm="Tem certeza que deseja excluir esta regra?"
                          class="btn btn-ghost btn-xs text-error"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
              <div
                id="no-rules-msg"
                class="p-10 text-center opacity-30 italic only:block hidden"
              >
                Nenhuma regra de transferência configurada.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    rules = Transactions.list_transfer_rules()
    accounts = Accounts.list_active_accounts()

    {:ok,
     socket
     |> assign(:accounts, accounts)
     |> assign(:current_rule, nil)
     |> assign(:form, build_form(%TransferRule{}))
     |> stream(:transfer_rules, rules)}
  end

  @impl true
  def handle_event("validate", %{"transfer_rule" => params}, socket) do
    rule = socket.assigns.current_rule || %TransferRule{}
    attrs = parse_form_params(params)

    form =
      rule
      |> Transactions.change_transfer_rule(attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("save", %{"transfer_rule" => params}, socket) do
    attrs = parse_form_params(params)

    result =
      case socket.assigns.current_rule do
        nil -> Transactions.create_transfer_rule(attrs)
        rule -> Transactions.update_transfer_rule(rule, attrs)
      end

    case result do
      {:ok, rule} ->
        rule = Transactions.get_transfer_rule!(rule.id)

        {:noreply,
         socket
         |> put_flash(:success, "Regra de transferência salva!")
         |> stream_insert(:transfer_rules, rule)
         |> assign(:current_rule, nil)
         |> assign(:form, build_form(%TransferRule{}))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    rule = Transactions.get_transfer_rule!(id)
    form = build_form(rule)

    {:noreply,
     socket
     |> assign(:current_rule, rule)
     |> assign(:form, form)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_rule, nil)
     |> assign(:form, build_form(%TransferRule{}))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    rule = Transactions.get_transfer_rule!(id)
    {:ok, _} = Transactions.delete_transfer_rule(rule)

    {:noreply,
     socket
     |> stream_delete(:transfer_rules, rule)
     |> put_flash(:success, "Regra de transferência excluída.")}
  end

  defp build_form(rule) do
    patterns_raw = Enum.join(rule.description_patterns || [], ", ")

    rule
    |> Transactions.change_transfer_rule(%{})
    |> to_form()
    |> Map.update!(:params, fn params ->
      Map.put(params, "description_patterns_raw", patterns_raw)
    end)
  end

  defp parse_form_params(params) do
    raw = Map.get(params, "description_patterns_raw", "")

    patterns =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    params
    |> Map.delete("description_patterns_raw")
    |> Map.put("description_patterns", patterns)
  end

  defp account_options(accounts) do
    Enum.map(accounts, fn a -> {account_label(a), a.id} end)
  end
end
