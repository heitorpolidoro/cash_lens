defmodule CashLensWeb.AccountLive.Form do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Accounts.Account

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@page_title}
      <:subtitle>Use este formulário para gerenciar os dados da sua conta bancária.</:subtitle>
    </.header>

                <.form for={@form} id="account-form" phx-change="validate" phx-submit="save">
                  <.input field={@form[:name]} type="text" label="Nome" />
                  <.input field={@form[:bank]} type="text" label="Banco" />
                  <.input field={@form[:balance]} type="number" label="Saldo Inicial" step="any" />
                          <.input field={@form[:color]} type="text" label="Cor (opcional)" />
                          
                          <div class="form-control">
                            <label class="label cursor-pointer justify-start gap-4">
                              <input type="hidden" name="account[accepts_import]" value="false" />
                              <input type="checkbox" name="account[accepts_import]" value="true" checked={@form[:accepts_import].value} class="checkbox checkbox-primary" />
                              <span class="label-text font-bold">Aceita importar extratos?</span>
                            </label>
                          </div>
                  
                          <div class="flex items-end gap-4">
                  
                    <div class="flex-1">
                      <.input field={@form[:icon]} type="text" label="URL do Ícone (opcional)" />
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
          
                  <footer>
                  <.button phx-disable-with="Salvando..." variant="primary">Salvar Conta</.button>
        <.button navigate={return_path(@return_to, @account)}>Cancelar</.button>
      </footer>
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
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    account = Accounts.get_account!(id)

    socket
    |> assign(:page_title, "Editar Conta")
    |> assign(:account, account)
    |> assign(:form, to_form(Accounts.change_account(account)))
  end

  defp apply_action(socket, :new, _params) do
    account = %Account{}

    socket
    |> assign(:page_title, "Nova Conta")
    |> assign(:account, account)
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
    case Accounts.update_account(socket.assigns.account, account_params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conta atualizada com sucesso")
         |> push_navigate(to: return_path(socket.assigns.return_to, account))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_account(socket, :new, account_params) do
    case Accounts.create_account(account_params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conta criada com sucesso")
         |> push_navigate(to: return_path(socket.assigns.return_to, account))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _account), do: ~p"/accounts"
  defp return_path("show", account), do: ~p"/accounts/#{account}"
end
