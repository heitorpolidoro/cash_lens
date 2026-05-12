defmodule CashLensWeb.AccountLive.Form do
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Accounts.Account

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@page_title}
      <:subtitle>Use this form to manage your bank account data and balances.</:subtitle>
    </.header>

    <.form for={@form} id="account-form" phx-change="validate" phx-submit="save">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6 bg-base-200/30 p-6 rounded-2xl border border-base-300 mb-8">
        <div class="space-y-4">
          <h3 class="text-sm font-black uppercase tracking-wider opacity-40">Account Details</h3>
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:bank]} type="text" label="Bank" />
          <.input
            field={@form[:parser_type]}
            type="select"
            label="Extractor"
            options={[
              {"Banco do Brasil (CSV)", "bb_csv"},
              {"Sem Parar (PDF)", "sem_parar_pdf"},
              {"Standard OFX", "standard_ofx"}
            ]}
            prompt="Select an extractor"
          />
        </div>

        <div class="space-y-4">
          <h3 class="text-sm font-black uppercase tracking-wider opacity-40">Balance Management</h3>
          <.input field={@form[:balance]} type="number" label="Initial Balance (Seed)" step="any" />

          <div :if={@live_action == :edit} class="space-y-1">
            <.input
              field={@form[:current_balance]}
              type="number"
              label="Current Balance (Adjust)"
              step="any"
              phx-debounce="blur"
            />
            <p class="text-[10px] opacity-50 px-1">
              Adjusting this value will automatically shift the Initial Balance to match.
            </p>
          </div>

          <div :if={@live_action == :new} class="bg-info/10 p-3 rounded-lg border border-info/20">
            <p class="text-xs text-info leading-relaxed">
              For new accounts, the Initial Balance is the starting point. Current Balance will be calculated based on transactions.
            </p>
          </div>
        </div>
      </div>

      <div class="space-y-6">
        <div class="flex flex-wrap gap-6">
          <.input field={@form[:accepts_import]} type="checkbox" label="Accepts statement imports?" />
          <.input field={@form[:color]} type="text" label="Color (optional)" class="w-32" />
        </div>

        <div class="flex items-end gap-4">
          <div class="flex-1">
            <.input field={@form[:icon]} type="text" label="Icon URL (optional)" />
          </div>
          <div class="avatar pb-2">
            <div class="w-12 rounded-full border border-base-300 bg-base-200 flex items-center justify-center overflow-hidden">
              <%= if @form[:icon].value && @form[:icon].value != "" do %>
                <img src={@form[:icon].value} />
              <% else %>
                <.icon name="hero-photo" class="size-6 opacity-20" />
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <div class="mt-8 flex flex-col sm:flex-row gap-3">
        <.button phx-disable-with="Saving..." variant="primary" class="flex-1">
          Save Account
        </.button>
        <.button
          type="button"
          navigate={return_path(@return_to, @account)}
          class="btn btn-error btn-outline flex-1"
        >
          Cancel
        </.button>
      </div>
    </.form>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to("transactions"), do: "transactions"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    account = Accounts.get_account!(id)
    latest_balance = Accounting.get_latest_balance_for_account(account.id)
    current_balance = if latest_balance, do: latest_balance.final_balance, else: account.balance

    socket
    |> assign(:page_title, "Edit Account")
    |> assign(:account, account)
    |> assign(:current_balance_on_load, current_balance)
    |> assign(
      :form,
      to_form(Accounts.change_account(account, %{current_balance: current_balance}))
    )
  end

  defp apply_action(socket, :new, _params) do
    account = %Account{}

    socket
    |> assign(:page_title, "New Account")
    |> assign(:account, account)
    |> assign(:current_balance_on_load, nil)
    |> assign(:form, to_form(Accounts.change_account(account)))
  end

  @impl true
  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset = Accounts.change_account(socket.assigns.account, account_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"account" => account_params}, socket) do
    save_account(socket, socket.assigns.live_action, account_params)
  end

  defp save_account(socket, :edit, account_params) do
    # 1. Handle current balance adjustment logic
    adjusted_params =
      case {account_params["current_balance"], socket.assigns.current_balance_on_load} do
        {new_current_str, original_current}
        when is_binary(new_current_str) and new_current_str != "" ->
          new_current = Decimal.new(new_current_str)

          if Decimal.equal?(new_current, original_current) do
            account_params
          else
            # delta = new_current - original_current
            delta = Decimal.sub(new_current, original_current)
            # new_initial = original_initial + delta
            original_initial = socket.assigns.account.balance || Decimal.new("0")
            new_initial = Decimal.add(original_initial, delta)

            Map.put(account_params, "balance", new_initial)
          end

        _ ->
          account_params
      end

    previous_initial_balance = socket.assigns.account.balance

    case Accounts.update_account(socket.assigns.account, adjusted_params) do
      {:ok, account} ->
        # If the root initial balance changed (either directly or via current balance adjustment)
        if not Decimal.equal?(previous_initial_balance, account.balance) do
          Accounting.rebuild_account_balances(account.id)
        end

        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, account))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_account(socket, :new, account_params) do
    case Accounts.create_account(account_params) do
      {:ok, account} ->
        # No need to rebuild for new account (no transactions yet)
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, account))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _account), do: ~p"/accounts"
  defp return_path("show", account), do: ~p"/accounts/#{account}"
  defp return_path("transactions", _account), do: ~p"/transactions"
end
