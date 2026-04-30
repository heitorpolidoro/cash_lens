defmodule CashLensWeb.BalanceLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Listing Balances
        <:actions>
          <button phx-click="recalculate_all" class="btn btn-outline btn-warning">
            <.icon name="hero-arrow-path-rounded-square" class="mr-1" /> Recalculate All
          </button>
          <.link navigate={~p"/balances/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> New Balance
            </.button>
          </.link>
        </:actions>
      </.header>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <form id="filter-form" phx-change="filter">
          <table class="table table-zebra w-full text-xs">
            <thead class="bg-base-200/50">
              <tr>
                <th class="w-48">
                  <div class="flex flex-col gap-1">
                    <span>Account</span>
                    <select
                      name="account_id"
                      class="select select-bordered select-xs font-normal w-full"
                    >
                      <option value="">All</option>
                      <%= for account <- @accounts do %>
                        <option value={account.id} selected={@filters["account_id"] == account.id}>
                          {account.name}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="w-24">
                  <div class="flex flex-col gap-1">
                    <span>Year</span>
                    <select name="year" class="select select-bordered select-xs font-normal w-full">
                      <option value="">All</option>
                      <%= for year <- 2024..2030 do %>
                        <option value={year} selected={@filters["year"] == to_string(year)}>
                          {year}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="w-32">
                  <div class="flex flex-col gap-1">
                    <span>Month</span>
                    <select name="month" class="select select-bordered select-xs font-normal w-full">
                      <option value="">All</option>
                      <%= for {name, num} <- month_options() do %>
                        <option value={num} selected={@filters["month"] == to_string(num)}>
                          {name}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1">
                    <span>Initial Balance</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1">
                    <span>Income</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1">
                    <span>Expenses</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1 font-black">
                    <span>Final Balance</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="w-16 text-center">
                  <div class="flex flex-col gap-1 items-center">
                    <span class="opacity-0">Reset</span>
                    <button
                      type="button"
                      phx-click="clear_filters"
                      class="btn btn-ghost btn-xs text-error p-0"
                      title="Clear filters"
                    >
                      <.icon name="hero-x-circle" class="size-4" />
                    </button>
                  </div>
                </th>
              </tr>
            </thead>
            <tbody id="balances" phx-update="stream">
              <tr
                :for={{id, balance} <- @streams.balances}
                id={id}
                class="hover group border-b border-base-200"
              >
                <td>
                  <div class="flex items-center gap-3">
                    <div class="avatar placeholder text-[10px]">
                      <div class="w-8 rounded-full bg-base-300">
                        <%= if balance.account && balance.account.icon && balance.account.icon != "" do %>
                          <img src={balance.account.icon} />
                        <% else %>
                          <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content font-bold uppercase">
                            {if balance.account,
                              do: String.slice(balance.account.bank || balance.account.name, 0..1),
                              else: "?"}
                          </div>
                        <% end %>
                      </div>
                    </div>
                    <span class="font-bold truncate max-w-[120px]">
                      {if balance.account, do: balance.account.name, else: "Deleted account"}
                    </span>
                  </div>
                </td>
                <td class="opacity-70">{balance.year}</td>
                <td>{translate_month_num(balance.month)}</td>
                <td class="text-right opacity-70">{format_currency(balance.initial_balance)}</td>
                <td class="text-right text-success font-medium">{format_currency(balance.income)}</td>
                <td class="text-right text-error font-medium">{format_currency(balance.expenses)}</td>
                <td class="text-right font-black bg-base-200/30">
                  {format_currency(balance.final_balance)}
                </td>

                <td class="text-right">
                  <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                    <.link
                      navigate={~p"/balances/#{balance}/edit"}
                      class="btn btn-ghost btn-xs px-1"
                      phx-click-stop
                    >
                      <.icon name="hero-pencil" class="size-3" />
                    </.link>
                    <button
                      type="button"
                      phx-click="confirm_delete"
                      phx-value-id={balance.id}
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
        </form>
      </div>
    </div>

    <!-- Modal de Confirmação -->
    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">Delete Balance?</h2>
        <p class="text-base-content/60 mb-10">
          Do you really want to delete this monthly balance record?
        </p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">
            Yes, Delete
          </button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
            Cancel
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
     |> assign(:page_title, "Balances")
     |> assign(:confirm_modal, nil)
     |> assign(:accounts, Accounts.list_accounts())
     |> assign(:filters, %{"account_id" => "", "month" => "", "year" => ""})
     |> stream(:balances, Accounting.list_balances())}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filters, params)
     |> stream(:balances, Accounting.list_balances(params), reset: true)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = %{"account_id" => "", "month" => "", "year" => ""}

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> stream(:balances, Accounting.list_balances(filters), reset: true)}
  end

  @impl true
  def handle_event("recalculate_all", _params, socket) do
    Accounting.recalculate_all_balances()

    {:noreply,
     socket
     |> put_flash(:info, "All balances have been recalculated in cascade!")
     |> stream(:balances, Accounting.list_balances(socket.assigns.filters), reset: true)}
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
    balance = Accounting.get_balance!(id)
    {:ok, _} = Accounting.delete_balance(balance)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:balances, balance)}
  end

  defp translate_month_num(num) do
    Enum.at(
      ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
      num - 1
    )
  end

  defp month_options do
    [
      {"January", 1},
      {"February", 2},
      {"March", 3},
      {"April", 4},
      {"May", 5},
      {"June", 6},
      {"July", 7},
      {"August", 8},
      {"September", 9},
      {"October", 10},
      {"November", 11},
      {"December", 12}
    ]
  end
end
