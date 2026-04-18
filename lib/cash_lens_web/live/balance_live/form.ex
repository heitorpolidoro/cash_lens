defmodule CashLensWeb.BalanceLive.Form do
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8">
      <.header>
        {@page_title}
        <:subtitle>
          {if @live_action == :new,
            do: "Escolha a conta e o período para consolidar os valores.",
            else: "Ajuste manualmente os valores consolidados do balanço."}
        </:subtitle>
      </.header>

      <.form
        :let={_f}
        for={@form}
        id="balance-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-8 mt-8"
      >
        <div class="space-y-6 bg-base-100 p-8 rounded-3xl border border-base-300 shadow-sm">
          <%= if @live_action == :new do %>
            <!-- MODO CRIAÇÃO: Seleção para Geração Automática -->
            <div class="form-control">
              <label class="label mb-2">
                <span class="label-text font-black text-lg text-primary">1. Selecione as Contas</span>
              </label>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <%= for account <- @accounts do %>
                  <label class="flex items-center gap-3 p-3 border-2 border-base-300 rounded-2xl cursor-pointer hover:bg-base-200 transition-all has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                    <input
                      type="checkbox"
                      name="account_ids[]"
                      value={account.id}
                      class="checkbox checkbox-primary"
                      checked={account.id in @selected_account_ids}
                    />
                    <div class="flex flex-col">
                      <span class="font-bold text-sm">{account.name}</span>
                      <span class="text-[10px] opacity-50 uppercase tracking-wider">
                        {account.bank}
                      </span>
                    </div>
                  </label>
                <% end %>
              </div>
              <div class="mt-4 flex gap-2">
                <button type="button" phx-click="select_all" class="btn btn-ghost btn-xs text-primary">
                  Selecionar Todas
                </button>
                <button type="button" phx-click="select_none" class="btn btn-ghost btn-xs text-error">
                  Limpar Seleção
                </button>
              </div>
            </div>

            <div class="divider"></div>

            <div class="grid grid-cols-2 gap-6">
              <.input
                field={@form[:month]}
                type="select"
                label="2. Mês"
                options={[
                  {"Janeiro", 1},
                  {"Fevereiro", 2},
                  {"Março", 3},
                  {"Abril", 4},
                  {"Maio", 5},
                  {"Junho", 6},
                  {"Julho", 7},
                  {"Agosto", 8},
                  {"Setembro", 9},
                  {"Outubro", 10},
                  {"Novembro", 11},
                  {"Dezembro", 12}
                ]}
              />
              <.input
                field={@form[:year]}
                type="select"
                label="3. Ano"
                options={Enum.map(2024..2030, &{&1, &1})}
              />
            </div>
          <% else %>
            <!-- MODO EDIÇÃO: Ajuste Manual de Valores -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div class="md:col-span-2 bg-base-200/50 p-4 rounded-xl border border-base-300 mb-2">
                <p class="text-xs uppercase font-bold opacity-50">Dados do Período</p>
                <p class="font-black text-lg">
                  {@balance.account.name} — {translate_month_num(@balance.month)}/{@balance.year}
                </p>
              </div>

              <.input field={@form[:initial_balance]} type="number" label="Saldo Inicial" step="any" />
              <.input field={@form[:final_balance]} type="number" label="Saldo Final" step="any" />
              <.input field={@form[:income]} type="number" label="Entradas (Receitas)" step="any" />
              <.input field={@form[:expenses]} type="number" label="Saídas (Despesas)" step="any" />
              <.input
                field={@form[:balance]}
                type="number"
                label="Balanço Líquido (Mês)"
                step="any"
              />
            </div>
          <% end %>
        </div>

        <div class="flex flex-col gap-3">
          <.button
            phx-disable-with="Salvando..."
            class="w-full btn-primary btn-lg shadow-xl shadow-primary/20 rounded-2xl"
          >
            <.icon name="hero-check-circle" class="size-5 mr-2" />
            {if @live_action == :new, do: "Gerar Balanços Selecionados", else: "Salvar Alterações"}
          </.button>

          <.link navigate={~p"/balances"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-3 mr-1" /> Voltar para lista
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:accounts, Accounts.list_accounts())
     |> assign(:selected_account_ids, [])
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    balance = Accounting.get_balance!(id)

    socket
    |> assign(:page_title, "Editar Balanço")
    |> assign(:balance, balance)
    |> assign(:form, to_form(Accounting.change_balance(balance)))
  end

  defp apply_action(socket, :new, _params) do
    now = Date.utc_today()

    socket
    |> assign(:page_title, "Gerar Balanços Mensais")
    |> assign(:form, to_form(%{"month" => now.month, "year" => now.year}))
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    ids = Enum.map(socket.assigns.accounts, & &1.id)
    {:noreply, assign(socket, :selected_account_ids, ids)}
  end

  @impl true
  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected_account_ids, [])}
  end

  @impl true
  def handle_event("validate", %{"account_ids" => ids} = params, socket) do
    {:noreply, assign(socket, selected_account_ids: ids, form: to_form(params))}
  end

  def handle_event("validate", %{"balance" => balance_params}, socket) do
    changeset = Accounting.change_balance(socket.assigns.balance, balance_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, form: to_form(params))}
  end

  @impl true
  def handle_event("save", params, socket) do
    save_balance(socket, socket.assigns.live_action, params)
  end

  defp save_balance(socket, :new, %{
         "account_ids" => account_ids,
         "month" => month,
         "year" => year
       }) do
    month = if is_binary(month), do: String.to_integer(month), else: month
    year = if is_binary(year), do: String.to_integer(year), else: year
    Enum.each(account_ids, fn id -> Accounting.calculate_monthly_balance(id, year, month) end)

    {:noreply,
     socket |> put_flash(:info, "Balanços gerados!") |> push_navigate(to: ~p"/balances")}
  end

  defp save_balance(socket, :new, _params),
    do: {:noreply, put_flash(socket, :error, "Selecione ao menos uma conta.")}

  defp save_balance(socket, :edit, %{"balance" => balance_params}) do
    case Accounting.update_balance(socket.assigns.balance, balance_params) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Balanço atualizado!") |> push_navigate(to: ~p"/balances")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp translate_month_num(num) do
    Enum.at(
      [
        "Janeiro",
        "Fevereiro",
        "Março",
        "Abril",
        "Maio",
        "Junho",
        "Julho",
        "Agosto",
        "Setembro",
        "Outubro",
        "Novembro",
        "Dezembro"
      ],
      num - 1
    )
  end
end
