defmodule CashLensWeb.TransactionLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Parsers.Ingestor

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <div :if={@filters["account_id"] != ""} class="mb-2">
        <.link
          navigate={if @return_to == "accounts", do: ~p"/accounts", else: ~p"/"}
          class="text-xs font-black uppercase opacity-50 hover:opacity-100 flex items-center gap-1 transition-all group"
        >
          <.icon
            name="hero-arrow-left"
            class="size-3 group-hover:-translate-x-1 transition-transform"
          /> Voltar para {if @return_to == "accounts", do: "Contas", else: "Dashboard"}
        </.link>
      </div>
      <.header>
        Transações
        <:subtitle :if={@filters["account_id"] not in ["", nil]}>
          Filtrando por conta: {case Enum.find(@accounts, &(&1.id == @filters["account_id"])) do
            nil -> "Desconhecida"
            acc -> acc.name
          end}
        </:subtitle>
        <:actions>
          <div class="dropdown dropdown-end">
            <button tabindex="0" class="btn btn-outline border-base-300 btn-sm">
              <.icon name="hero-ellipsis-vertical" class="size-4" /> Ações
            </button>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52 mt-2 border border-base-200"
            >
              <li>
                <.link navigate={~p"/transactions/new"}>
                  <.icon name="hero-plus" class="size-4" /> Nova Transação
                </.link>
              </li>
              <li>
                <button type="button" phx-click="open_import">
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Importar Extratos
                </button>
              </li>
              <li>
                <button type="button" phx-click="auto_categorize_all">
                  <.icon name="hero-sparkles" class="size-4" /> Auto-Categorizar
                </button>
              </li>
              <li>
                <.link navigate={~p"/reimbursements"}>
                  <.icon name="hero-banknotes" class="size-4" /> Reembolsos
                </.link>
              </li>
              <li>
                <.link navigate={~p"/admin/exclusion_rules"}>
                  <.icon name="hero-no-symbol" class="size-4" /> Regras de Exclusão
                </.link>
              </li>
              <div class="divider my-1"></div>
              <li>
                <button type="button" phx-click="confirm_delete_all" class="text-error">
                  <.icon name="hero-trash" class="size-4" /> Limpar Tudo
                </button>
              </li>
            </ul>
          </div>
        </:actions>
      </.header>

      <div class="flex items-center justify-between flex-wrap gap-4 bg-base-100 p-4 rounded-2xl border border-base-300 shadow-sm">
        <div class="flex items-center gap-4 flex-wrap">
          <div class="join shadow-sm border border-base-300">
            <button
              type="button"
              phx-click="toggle_type"
              phx-value-type="debit"
              class={[
                "join-item btn btn-sm px-4",
                if(@filters["type"] == "debit",
                  do: "btn-error",
                  else: "bg-base-100 border-none hover:bg-base-200"
                )
              ]}
            >
              <.icon name="hero-arrow-trending-down" class="size-4 mr-1" /> Débitos
            </button>
            <button
              type="button"
              phx-click="toggle_type"
              phx-value-type="credit"
              class={[
                "join-item btn btn-sm px-4",
                if(@filters["type"] == "credit",
                  do: "btn-success",
                  else: "bg-base-100 border-none hover:bg-base-200"
                )
              ]}
            >
              <.icon name="hero-arrow-trending-up" class="size-4 mr-1" /> Créditos
            </button>
          </div>

          <div class={[
            "join shadow-sm border border-base-300 bg-base-100 transition-opacity",
            (@filters["category_id"] == "nil" or @filters["unmatched_transfers"] == "true") &&
              "opacity-30 pointer-events-none grayscale"
          ]}>
            <button
              type="button"
              phx-click="prev_month"
              class="join-item btn btn-sm btn-ghost px-2"
              title="Mês Anterior"
              disabled={@filters["category_id"] == "nil" or @filters["unmatched_transfers"] == "true"}
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>

            <form id="month-selector" phx-change="apply_filters" class="m-0 p-0 flex">
              <input type="hidden" name="type" value={@filters["type"]} />
              <input type="hidden" name="search" value={@filters["search"]} />

              <input type="hidden" name="account_id" value={@filters["account_id"]} />
              <input type="hidden" name="category_id" value={@filters["category_id"]} />
              <input type="hidden" name="sort_order" value={@filters["sort_order"]} />
              <input type="hidden" name="unmatched_transfers" value={@filters["unmatched_transfers"]} />

              <select
                name="month"
                class="join-item select select-xs h-8 bg-transparent border-none focus:ring-0 font-bold uppercase text-[10px]"
                disabled={
                  @filters["category_id"] == "nil" or @filters["unmatched_transfers"] == "true"
                }
              >
                <option value="" selected={@filters["month"] == ""}>Todos os Meses</option>
                <%= for {m_name, m_val} <- [{"Jan", 1}, {"Fev", 2}, {"Mar", 3}, {"Abr", 4}, {"Mai", 5}, {"Jun", 6}, {"Jul", 7}, {"Ago", 8}, {"Set", 9}, {"Out", 10}, {"Nov", 11}, {"Dez", 12}] do %>
                  <option value={m_val} selected={@filters["month"] == "#{m_val}"}>{m_name}</option>
                <% end %>
              </select>

              <input
                :if={@filters["month"] == ""}
                type="hidden"
                name="year"
                value={@filters["year"] || Date.utc_today().year}
              />

              <div :if={@filters["month"] != ""} class="join-item flex items-center px-1 opacity-20">
                /
              </div>

              <select
                :if={@filters["month"] != ""}
                name="year"
                class="join-item select select-xs h-8 bg-transparent border-none focus:ring-0 font-bold uppercase text-[10px]"
                disabled={
                  @filters["category_id"] == "nil" or @filters["unmatched_transfers"] == "true"
                }
              >
                <%= for y <- (Date.utc_today().year - 5)..(Date.utc_today().year + 1) do %>
                  <option value={y} selected={@filters["year"] == "#{y}"}>{y}</option>
                <% end %>
              </select>
            </form>

            <button
              type="button"
              phx-click="next_month"
              class="join-item btn btn-sm btn-ghost px-2"
              title="Próximo Mês"
              disabled={@filters["category_id"] == "nil" or @filters["unmatched_transfers"] == "true"}
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="toggle_pending"
            class={[
              "btn btn-sm shadow-sm",
              if(@filters["category_id"] == "nil",
                do: "btn-warning",
                else: "btn-outline border-base-300"
              )
            ]}
          >
            <.icon name="hero-exclamation-triangle" class="size-4 mr-1" />
            Pendentes ({@pending_count})
          </button>

          <button
            type="button"
            phx-click="toggle_unmatched"
            class={[
              "btn btn-sm shadow-sm",
              if(@filters["unmatched_transfers"] == "true",
                do: "btn-secondary",
                else: "btn-outline border-base-300"
              )
            ]}
          >
            <.icon name="hero-link-slash" class="size-4 mr-1" />
            Transferências sem par ({@unmatched_transfers_count})
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <!-- Card de Saldo -->
        <div
          class={[
            "stats shadow bg-base-100 border border-base-300 transition-all",
            @filters["account_id"] != "" && "hover:border-primary cursor-pointer active:scale-95"
          ]}
          phx-click={@filters["account_id"] != "" && "open_balance_correction"}
        >
          <div class="stat">
            <div class="stat-title flex items-center gap-2">
              Saldo
              <.icon
                :if={@filters["account_id"] != ""}
                name="hero-pencil-square"
                class="size-3 opacity-30"
              />
            </div>
            <div class="stat-value text-primary font-black text-2xl">
              {format_currency(@summary.current_balance)}
            </div>
            <div class="stat-desc">
              {if @filters["account_id"] != "",
                do: "Saldo desta conta",
                else: "Soma de todas as contas"}
            </div>
          </div>
        </div>
        
    <!-- Card de Receitas -->
        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title text-success flex items-center gap-1">
              <.icon name="hero-arrow-up-circle" class="size-3" /> Receitas ({@summary.month_name})
            </div>
            <div class="stat-value text-success font-black text-2xl">
              {format_currency(@summary.income)}
            </div>
            <div class="stat-desc">
              Ganhos {if @filters["account_id"] != "", do: "nesta conta", else: "em todas as contas"}
            </div>
          </div>
        </div>
        
    <!-- Card de Despesas -->
        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title text-error flex items-center gap-1">
              <.icon name="hero-arrow-down-circle" class="size-3" /> Despesas ({@summary.month_name})
            </div>
            <div class="stat-value text-error font-black text-2xl">
              {format_currency(@summary.expenses)}
            </div>
            <div class="stat-desc">
              Gastos {if @filters["account_id"] != "", do: "nesta conta", else: "em todas as contas"}
            </div>
          </div>
        </div>
        
    <!-- Card de Balanço -->
        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title font-bold flex items-center gap-1">
              <.icon name="hero-scale" class="size-3" /> Balanço ({@summary.month_name})
            </div>
            <% balance = Decimal.sub(@summary.income, @summary.expenses) %>
            <div class={[
              "stat-value font-black text-2xl",
              if(Decimal.gt?(balance, 0), do: "text-success", else: "text-error")
            ]}>
              {format_currency(balance)}
            </div>
            <div class="stat-desc">Resultado no mês</div>
          </div>
        </div>
      </div>
      
    <!-- Modal de Correção de Saldo -->
      <.modal
        :if={@show_balance_correction}
        id="balance-correction-modal"
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Corrigir Saldo
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Ajustando saldo da conta:
            <strong>{Enum.find(@accounts, &(&1.id == @filters["account_id"])).name}</strong>
          </p>

          <.form
            :let={f}
            for={@balance_correction_form}
            id="balance-correction-form"
            phx-submit="save_balance_correction"
            class="space-y-6"
          >
            <div class="space-y-1">
              <label class="block text-xs font-black uppercase opacity-40">
                Saldo Atual Registrado
              </label>
              <div class="text-xl font-mono font-bold">
                {format_currency(@summary.current_balance)}
              </div>
            </div>

            <div class="space-y-2">
              <.input
                field={f[:new_balance]}
                type="number"
                label="Novo Saldo Real"
                step="0.01"
                required
                placeholder="0.00"
                phx-keyup="update_diff"
                class="text-lg font-mono [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
              />

              <div
                :if={!Decimal.eq?(@balance_diff, 0)}
                class="flex items-center gap-2 px-3 py-2 bg-base-200 rounded-lg border border-base-300 animate-in fade-in slide-in-from-top-1 duration-200"
              >
                <span class="text-[10px] font-black uppercase opacity-50 text-nowrap">
                  Diferença (Ajuste):
                </span>
                <span class={[
                  "font-mono font-bold text-sm",
                  if(Decimal.gt?(@balance_diff, 0), do: "text-success", else: "text-error")
                ]}>
                  {if Decimal.gt?(@balance_diff, 0), do: "+", else: ""}{format_currency(@balance_diff)}
                </span>
              </div>
            </div>

            <div class="space-y-3">
              <label class="block text-sm font-bold text-primary">Como aplicar o ajuste?</label>
              <div class="flex flex-col gap-2">
                <label class="flex items-center gap-3 p-3 border border-base-300 rounded-xl cursor-pointer hover:bg-base-200 transition-all has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                  <input
                    type="radio"
                    name="adjustment_type"
                    value="rendimentos"
                    class="radio radio-primary"
                    checked
                  />
                  <div>
                    <span class="block font-bold text-sm">Rendimentos</span>
                    <span class="block text-[10px] opacity-60">
                      Cria uma nova transação com a diferença de valor.
                    </span>
                  </div>
                </label>
                <label class="flex items-center gap-3 p-3 border border-base-300 rounded-xl cursor-pointer hover:bg-base-200 transition-all has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                  <input
                    type="radio"
                    name="adjustment_type"
                    value="ajuste_inicial"
                    class="radio radio-primary"
                  />
                  <div>
                    <span class="block font-bold text-sm">Ajuste Inicial</span>
                    <span class="block text-[10px] opacity-60">
                      Altera o saldo do balanço mais antigo e recalcula o histórico.
                    </span>
                  </div>
                </label>
              </div>
            </div>

            <div class="pt-2">
              <.button phx-disable-with="Ajustando..." variant="primary" class="w-full">
                Confirmar Ajuste
              </.button>
            </div>
          </.form>
        </div>
      </.modal>
      
    <!-- Tabela Unificada com Filtros -->
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="overflow-x-auto">
          <form id="transaction-filters" phx-change="apply_filters" class="m-0 p-0">
            <input type="hidden" name="sort_order" value={@filters["sort_order"]} />
            <input type="hidden" name="type" value={@filters["type"]} />
            <input type="hidden" name="month" value={@filters["month"]} />
            <input type="hidden" name="year" value={@filters["year"]} />
            <input type="hidden" name="unmatched_transfers" value={@filters["unmatched_transfers"]} />
            <table class="table table-zebra w-full text-xs table-fixed">
              <thead class="bg-base-200/50">
                <tr>
                  <th class="w-40 px-4">
                    <div class="flex flex-col gap-1">
                      <div class="flex items-center justify-between pr-2">
                        <span>Data</span>
                        <button
                          type="button"
                          phx-click="toggle_sort"
                          class="btn btn-ghost btn-xs p-0 hover:bg-transparent"
                          title="Alternar ordenação"
                        >
                          <.icon
                            name={
                              if @filters["sort_order"] == "desc",
                                do: "hero-chevron-down",
                                else: "hero-chevron-up"
                            }
                            class="size-4"
                          />
                        </button>
                      </div>
                      <input
                        type="date"
                        name="date"
                        value={@filters["date"]}
                        class="input input-bordered input-xs font-normal w-full"
                      />
                    </div>
                  </th>
                  <th class="px-4">
                    <div class="flex flex-col gap-1">
                      <span>Descrição</span>
                      <input
                        type="text"
                        name="search"
                        value={@filters["search"]}
                        placeholder="Buscar..."
                        class="input input-bordered input-xs font-normal w-full"
                        phx-debounce="300"
                      />
                    </div>
                  </th>
                  <th class="w-32 px-4">
                    <div class="flex flex-col gap-1 text-right">
                      <span>Valor</span>
                      <input
                        type="number"
                        name="amount"
                        value={@filters["amount"]}
                        placeholder="0.00"
                        step="any"
                        class="input input-bordered input-xs font-normal w-full text-right"
                        phx-debounce="300"
                      />
                    </div>
                  </th>
                  <th class="w-48 px-4">
                    <div class="flex flex-col gap-1">
                      <div class="flex items-center justify-between pr-2">
                        <span>Categoria</span>
                      </div>
                      <select
                        name="category_id"
                        class="select select-bordered select-xs font-normal w-full"
                      >
                        <option value="">Todas</option>
                        <option value="nil" selected={@filters["category_id"] == "nil"}>
                          Pendente
                        </option>
                        <%= for category <- @categories do %>
                          <option
                            value={category.id}
                            selected={@filters["category_id"] == category.id}
                          >
                            {CashLens.Categories.Category.full_name(category)}
                          </option>
                        <% end %>
                      </select>
                    </div>
                  </th>
                  <th class="w-40 px-4">
                    <div class="flex flex-col gap-1">
                      <span>Conta</span>
                      <select
                        name="account_id"
                        class="select select-bordered select-xs font-normal w-full"
                      >
                        <option value="">Todas</option>
                        <%= for account <- @accounts do %>
                          <option value={account.id} selected={@filters["account_id"] == account.id}>
                            {account.name}
                          </option>
                        <% end %>
                      </select>
                    </div>
                  </th>
                  <th class="w-24 px-4">
                    <div class="flex flex-col gap-1 items-center text-center">
                      <span class="opacity-0">Reset</span>
                      <button
                        type="button"
                        phx-click="clear_filters"
                        class="btn btn-ghost btn-xs text-error p-0"
                        title="Limpar filtros"
                      >
                        <.icon name="hero-x-circle" class="size-4" />
                      </button>
                    </div>
                  </th>
                </tr>
              </thead>
              <tbody id="transactions" phx-update="stream" class="overflow-visible">
                <tr
                  :for={{id, transaction} <- @streams.transactions}
                  id={id}
                  class="hover group border-b border-base-200 overflow-visible"
                >
                  <td class="whitespace-nowrap w-40 px-4">
                    <div class="flex flex-col">
                      <span class="font-medium text-base-content">
                        {format_date(transaction.date)}
                      </span>
                      <span class="text-[10px] opacity-50">
                        {if transaction.time, do: format_time(transaction.time), else: "--:--"} — {format_weekday(
                          transaction.date
                        )}
                      </span>
                    </div>
                  </td>
                  <td class="py-2 px-4 truncate max-w-xs md:max-w-md">
                    <div class="flex flex-col">
                      <div class="leading-relaxed font-medium truncate">
                        {transaction.description}
                      </div>
                      <div :if={transaction.reimbursement_status} class="flex items-center gap-1 mt-1">
                        <div class={[
                          "badge badge-xs text-[8px] uppercase font-black",
                          transaction.reimbursement_status == "paid" && "badge-success",
                          transaction.reimbursement_status == "requested" && "badge-info",
                          transaction.reimbursement_status == "pending" && "badge-warning"
                        ]}>
                          {CashLensWeb.Formatters.translate_reimbursement_status(
                            transaction.reimbursement_status,
                            transaction.amount
                          )}
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class={"w-32 px-4 text-right font-bold #{if Decimal.lt?(transaction.amount, 0), do: "text-error", else: "text-success"}"}>
                    {format_currency(transaction.amount)}
                  </td>
                  <td class="w-48 px-4 overflow-visible">
                    <div class="flex items-center gap-1 relative overflow-visible">
                      <div
                        id={"cat-select-#{transaction.id}"}
                        phx-hook="CategoryAutocomplete"
                        data-transaction-id={transaction.id}
                        data-categories={
                          Jason.encode!(
                            Enum.map(
                              @categories,
                              &%{id: &1.id, name: CashLens.Categories.Category.full_name(&1)}
                            )
                          )
                        }
                        class="relative w-full overflow-visible"
                        phx-click-stop
                      >
                        <div class="flex items-center gap-1 group/cat">
                          <input
                            type="text"
                            placeholder={
                              if transaction.category,
                                do: CashLens.Categories.Category.full_name(transaction.category),
                                else: "Pendente"
                            }
                            class={[
                              "input input-bordered input-xs w-full font-bold uppercase text-[9px] cursor-pointer",
                              is_nil(transaction.category_id) &&
                                "bg-warning text-warning-content border-warning/50"
                            ]}
                          />
                          <button
                            :if={transaction.category_id}
                            type="button"
                            phx-click="update_category"
                            phx-value-transaction_id={transaction.id}
                            phx-value-category_id=""
                            class="btn btn-ghost btn-xs p-0 text-error min-h-0 h-5 w-5 opacity-0 group-hover/cat:opacity-100 transition-opacity"
                            title="Limpar Categoria"
                          >
                            <.icon name="hero-x-mark" class="size-3" />
                          </button>
                        </div>
                        <div class="dropdown-content hidden absolute z-[100] mt-1 w-64 bg-base-100 border border-base-300 rounded-xl shadow-2xl overflow-hidden max-h-60 overflow-y-auto">
                          <ul class="menu menu-compact p-1">
                            <li class="new-option border-b border-base-200 mb-1">
                              <button
                                type="button"
                                class="font-black text-primary hover:bg-primary/10"
                              >
                                <.icon name="hero-plus-circle" class="size-4" />
                                <span>
                                  Nova Categoria
                                </span>
                              </button>
                            </li>
                          </ul>
                        </div>
                      </div>
                      <%= if transaction.category && transaction.category.slug == "transfer" do %>
                        <span title={
                          if transaction.transfer_key,
                            do: "Transferência vinculada",
                            else: "Transferência pendente de vínculo"
                        }>
                          <.icon
                            :if={transaction.transfer_key}
                            name="hero-link"
                            class="size-3 text-primary"
                          />
                          <.icon
                            :if={!transaction.transfer_key}
                            name="hero-exclamation-triangle"
                            class="size-3 text-warning"
                          />
                        </span>
                      <% end %>
                      <span :if={transaction.reimbursement_link_key} title="Reembolsado">
                        <.icon name="hero-shield-check" class="size-3 text-success" />
                      </span>
                    </div>
                  </td>
                  <td class="w-40 px-4 text-xs opacity-60 truncate">
                    {if transaction.account, do: transaction.account.name, else: "..."}
                  </td>
                  <td class="w-24 px-4 text-right">
                    <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                      <%= if transaction.reimbursement_status do %>
                        <button
                          type="button"
                          phx-click="unmark_reimbursable"
                          phx-value-id={transaction.id}
                          class="btn btn-ghost btn-xs text-error"
                          title="Remover marcação de reembolso"
                          aria-label="Remover Reembolso"
                        >
                          <.icon name="hero-x-circle" class="size-3" />
                        </button>
                      <% end %>

                      <%= if Decimal.lt?(transaction.amount, 0) && is_nil(transaction.reimbursement_status) do %>
                        <button
                          type="button"
                          phx-click="mark_reimbursable"
                          phx-value-id={transaction.id}
                          class="btn btn-ghost btn-xs text-primary"
                          title="Marcar Reembolsável"
                          aria-label="Marcar Reembolsável"
                        >
                          <.icon name="hero-banknotes" class="size-3" />
                        </button>
                      <% end %>
                      <%= if Decimal.gt?(transaction.amount, 0) && is_nil(transaction.reimbursement_link_key) do %>
                        <button
                          type="button"
                          phx-click="open_reimbursement_link"
                          phx-value-id={transaction.id}
                          class="btn btn-ghost btn-xs text-success"
                          title="Este é um reembolso"
                          aria-label="Vincular Reembolso"
                        >
                          <.icon name="hero-arrow-path" class="size-3" />
                        </button>
                      <% end %>
                      <%= if transaction.category && transaction.category.slug == "transfer" && is_nil(transaction.transfer_key) do %>
                        <button
                          type="button"
                          phx-click="open_transfer_link"
                          phx-value-id={transaction.id}
                          class="btn btn-ghost btn-xs text-primary"
                          title="Vincular par da transferência"
                          aria-label="Vincular Transferência"
                        >
                          <.icon name="hero-link" class="size-3" />
                        </button>
                      <% end %>
                      <.link
                        navigate={~p"/transactions/#{transaction}/edit"}
                        class="btn btn-ghost btn-xs px-1"
                        aria-label="Edit"
                      >
                        <.icon name="hero-pencil" class="size-3" />
                      </.link>
                      <button
                        type="button"
                        phx-click="confirm_delete"
                        phx-value-id={transaction.id}
                        class="btn btn-ghost btn-xs text-error px-1"
                        aria-label="Excluir"
                      >
                        <.icon name="hero-trash" class="size-3" />
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </form>
          <div id="infinite-scroll-sentinel" phx-hook="InfiniteScroll" data-page={@page}></div>
        </div>
      </div>

      <.modal :if={@show_transfer_modal} id="transfer-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Vincular Transferência
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Selecione abaixo o par correspondente para este lançamento de {format_currency(
              @transfer_origin.amount
            )}.
          </p>

          <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
            <%= if Enum.empty?(@pending_transfers) do %>
              <div class="text-center py-10 opacity-40 italic">
                Nenhum par correspondente encontrado para esta transferência.
              </div>
            <% end %>
            <%= for pending <- @pending_transfers do %>
              <button
                type="button"
                phx-click="link_transfer"
                phx-value-pair-id={pending.id}
                class="w-full text-left flex items-center justify-between p-3 border-2 border-base-300 rounded-xl hover:border-primary hover:bg-primary/5 transition-all group"
              >
                <div class="flex flex-col">
                  <span class="text-[9px] font-bold uppercase opacity-50">
                    {format_date(pending.date)} — {pending.account.name}
                  </span>
                  <span class="font-black text-md group-hover:text-primary">
                    {pending.description}
                  </span>
                </div>
                <div class="text-right">
                  <span class={[
                    "font-black text-md",
                    if(Decimal.lt?(pending.amount, 0), do: "text-error", else: "text-success")
                  ]}>
                    {format_currency(pending.amount)}
                  </span>
                </div>
              </button>
            <% end %>
          </div>

          <div class="mt-6 pt-6 border-t border-base-300">
            <button
              type="button"
              phx-click="open_quick_transfer"
              class="btn btn-outline btn-primary w-full rounded-2xl"
            >
              <.icon name="hero-plus-circle" class="size-4 mr-1" />
              Não encontrei o par, criar manualmente
            </button>
          </div>
        </div>
      </.modal>

      <.modal
        :if={@show_quick_transfer_modal}
        id="quick-transfer-modal"
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Criar Par da Transferência
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Confirme os dados abaixo para criar a transação correspondente na conta destino.
          </p>

          <.form
            :let={f}
            for={@quick_transfer_form}
            id="quick-transfer-form"
            phx-submit="save_quick_transfer"
            class="space-y-6"
          >
            <div class="grid grid-cols-2 gap-4">
              <.input field={f[:date]} type="date" label="Data" required readonly class="bg-base-200" />
              <.input
                field={f[:amount]}
                type="number"
                label="Valor"
                step="0.01"
                required
                readonly
                class="bg-base-200 font-bold"
              />
            </div>

            <.input
              field={f[:description]}
              type="text"
              label="Descrição"
              required
              placeholder="Ex: Transferência entre contas..."
            />

            <div class="form-control w-full">
              <label class="label">
                <span class="label-text font-bold text-primary">Conta Destino</span>
              </label>
              <select
                name="account_id"
                class="select select-bordered w-full rounded-2xl h-12"
                required
              >
                <option value="">Selecione a conta que recebeu/enviou</option>
                <%= for account <- Enum.reject(@accounts, & &1.id == @transfer_origin.account_id) do %>
                  <option value={account.id}>{account.name}</option>
                <% end %>
              </select>
            </div>

            <div class="pt-2">
              <.button phx-disable-with="Criando e vinculando..." variant="primary" class="w-full">
                Confirmar e Vincular
              </.button>
            </div>
          </.form>
        </div>
      </.modal>
      
    <!-- Modais Existentes -->
      <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-4 text-center">
          <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
            <.icon name="hero-trash" class="size-10" />
          </div>
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter">Excluir Transação?</h2>
          <p class="text-base-content/60 mb-10">
            Deseja realmente apagar esta transação? Esta ação não pode ser desfeita.
          </p>
          <div class="flex flex-col sm:flex-row gap-3">
            <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">
              Sim, Apagar
            </button>
            <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
              Cancelar
            </button>
          </div>
        </div>
      </.modal>

      <.modal :if={@show_import_modal} id="import-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter text-primary">
            Importar Extratos
          </h2>

          <form id="upload-form" phx-submit="save_import" phx-change="validate_import">
            <div class="form-control w-full mb-8">
              <label class="label">
                <span class="label-text font-black uppercase opacity-40 text-[10px]">
                  1. Selecione a Conta Destino
                </span>
              </label>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-2">
                <%= for account <- @import_accounts do %>
                  <label class={[
                    "flex items-center gap-3 p-3 border-2 rounded-2xl cursor-pointer hover:bg-base-200 transition-all group",
                    if(@import_account_id == account.id,
                      do: "border-primary bg-primary/5",
                      else: "border-base-300"
                    )
                  ]}>
                    <input
                      type="radio"
                      name="account_id"
                      value={account.id}
                      class="radio radio-primary radio-sm"
                      required
                      checked={@import_account_id == account.id}
                    />

                    <div class="avatar">
                      <div class="w-8 rounded-full bg-base-300 overflow-hidden">
                        <%= if account.icon && account.icon != "" do %>
                          <img src={account.icon} />
                        <% else %>
                          <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content text-[10px] font-bold">
                            {String.slice(account.bank || account.name, 0..1)}
                          </div>
                        <% end %>
                      </div>
                    </div>

                    <div class="min-w-0">
                      <span class="block font-bold text-sm truncate">{account.name}</span>
                      <span class="block text-[9px] opacity-50 uppercase font-black">
                        {translate_parser_type(account.parser_type)}
                      </span>
                    </div>
                  </label>
                <% end %>
              </div>
            </div>

            <div class="form-control w-full mb-8">
              <label class="label">
                <span class="label-text font-bold">2. Envie o arquivo (CSV ou PDF)</span>
              </label>
              <div class="p-10 border-2 border-dashed border-base-300 rounded-3xl bg-base-200/50 flex flex-col items-center justify-center group hover:border-primary transition-all cursor-pointer relative">
                <.live_file_input
                  upload={@uploads.statement}
                  class="absolute inset-0 opacity-0 cursor-pointer w-full h-full"
                />
                <.icon
                  name="hero-cloud-arrow-up"
                  class="size-12 opacity-20 mb-4 group-hover:text-primary group-hover:opacity-100 transition-all"
                />
                <p class="text-sm font-medium opacity-40">
                  Arraste seu arquivo ou clique para selecionar
                </p>
              </div>

              <div
                :for={entry <- @uploads.statement.entries}
                class="mt-4 p-3 bg-base-100 rounded-xl border border-base-300 flex items-center justify-between animate-in slide-in-from-left-2"
              >
                <div class="flex items-center gap-3">
                  <.icon name="hero-document-text" class="size-5 text-primary" />
                  <span class="text-xs font-bold truncate max-w-[200px]">{entry.client_name}</span>
                </div>
                <button
                  type="button"
                  phx-click={
                    JS.push("lv:cancel-upload", value: %{ref: entry.ref, upload: "statement"})
                  }
                  class="btn btn-ghost btn-xs text-error"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <button
              type="submit"
              class="btn btn-primary btn-lg w-full rounded-2xl shadow-lg shadow-primary/20"
              phx-disable-with="Processando..."
            >
              Iniciar Importação
            </button>
          </form>
        </div>
      </.modal>

      <.modal
        :if={@show_quick_category_modal}
        id="quick-category-modal"
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Nova Categoria
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Crie uma nova categoria para organizar seus lançamentos.
          </p>

          <.form
            :let={f}
            for={@category_form}
            id="quick-category-form"
            phx-submit="save_quick_category"
            class="space-y-6"
          >
            <.input
              field={f[:name]}
              type="text"
              label="Nome da Categoria"
              placeholder="Ex: Alimentação, Lazer..."
              required
            />

            <div class="form-control w-full">
              <label class="label">
                <span class="label-text font-bold">Categoria Pai (Opcional)</span>
              </label>
              <select name="parent_id" class="select select-bordered w-full rounded-2xl h-12">
                <option value="">Nenhuma (Categoria Principal)</option>
                <%= for cat <- Enum.filter(@categories, &is_nil(&1.parent_id)) do %>
                  <option value={cat.id}>{cat.name}</option>
                <% end %>
              </select>
            </div>

            <div class="pt-2">
              <button
                type="submit"
                class="btn btn-primary btn-lg w-full rounded-2xl shadow-lg shadow-primary/20"
                phx-disable-with="Criando..."
              >
                Salvar Categoria
              </button>
            </div>
          </.form>
        </div>
      </.modal>

      <.modal :if={@bulk_confirmation} id="bulk-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <div class="w-16 h-16 bg-primary/10 text-primary rounded-full flex items-center justify-center mb-6">
            <.icon name="hero-sparkles" class="size-8" />
          </div>
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter">Categorização em Massa</h2>
          <p class="text-sm opacity-70 mb-6">
            Encontramos mais <strong>{length(@bulk_confirmation.items)}</strong>
            transações com a descrição <span class="font-mono bg-base-300 px-1 rounded">"{@bulk_confirmation.description}"</span>.
            Deseja categorizar todas como <strong class="text-primary">{@bulk_confirmation.category_name}</strong>?
          </p>

          <div class="flex flex-col sm:flex-row gap-3">
            <button
              phx-click="apply_bulk_category"
              class="btn btn-primary btn-lg flex-1 rounded-2xl shadow-lg shadow-primary/20"
            >
              Sim, Categorizar Tudo
            </button>
            <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
              Não, Apenas Esta
            </button>
          </div>
        </div>
      </.modal>

      <.modal
        :if={@show_reimbursement_modal}
        id="reimbursement-modal"
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-success">
            Vincular Reembolso
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Selecione abaixo a despesa que foi coberta por este recebimento de {format_currency(
              @reimbursement_credit.amount
            )}.
          </p>
          
    <!-- Campo de Busca -->
          <div class="mb-6">
            <div class="relative">
              <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                <.icon name="hero-magnifying-glass" class="size-4 opacity-30" />
              </div>
              <input
                type="text"
                placeholder="Buscar por descrição ou valor..."
                class="input input-bordered w-full pl-10 h-12 rounded-2xl bg-base-200 border-none focus:ring-success"
                phx-keyup="reimbursement_search_change"
                phx-debounce="300"
                value={@reimbursement_search}
              />
            </div>
          </div>

          <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
            <%= if Enum.empty?(@pending_reimbursements) do %>
              <div class="text-center py-10 opacity-40 italic">
                Nenhuma despesa pendente de reembolso encontrada.
              </div>
            <% end %>
            <%= for pending <- @pending_reimbursements do %>
              <button
                type="button"
                phx-click="link_reimbursement"
                phx-value-expense-id={pending.id}
                class={[
                  "w-full text-left flex items-center justify-between p-3 border-2 rounded-xl hover:border-success hover:bg-success/5 transition-all group",
                  if(
                    Decimal.eq?(
                      Decimal.abs(Decimal.round(pending.amount, 2)),
                      Decimal.round(@reimbursement_credit.amount, 2)
                    ),
                    do: "border-success bg-success/5 shadow-lg shadow-success/10",
                    else: "border-base-300"
                  )
                ]}
              >
                <div class="flex flex-col">
                  <span class="text-[9px] font-bold uppercase opacity-50">
                    {format_date(pending.date)} — {pending.account.name}
                  </span>
                  <span class="font-black text-md group-hover:text-success">
                    {pending.description}
                  </span>
                  <div
                    :if={is_nil(pending.category_id)}
                    class="text-[8px] text-warning font-black uppercase mt-0.5"
                  >
                    Sem Categoria
                  </div>
                </div>
                <div class="text-right">
                  <span class="font-black text-md text-error">{format_currency(pending.amount)}</span>
                  <div
                    :if={
                      Decimal.eq?(
                        Decimal.abs(Decimal.round(pending.amount, 2)),
                        Decimal.round(@reimbursement_credit.amount, 2)
                      )
                    }
                    class="text-[8px] text-success font-black uppercase mt-0.5"
                  >
                    Match Perfeito!
                  </div>
                </div>
              </button>
            <% end %>
          </div>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CashLens.PubSub, "categories")
    accounts = Accounts.list_accounts()

    {:ok,
     socket
     |> assign(:page_title, "Transações")
     |> assign(:show_import_modal, false)
     |> assign(:show_quick_category_modal, false)
     |> assign(:show_reimbursement_modal, false)
     |> assign(:show_balance_correction, false)
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> assign(:transfer_origin, nil)
     |> assign(:pending_transfers, [])
     |> assign(:balance_correction_form, to_form(%{"new_balance" => ""}))
     |> assign(:quick_transfer_form, to_form(%{}))
     |> assign(:balance_diff, Decimal.new("0"))
     |> assign(:reimbursement_credit, nil)
     |> assign(:reimbursement_search, "")
     |> assign(:pending_reimbursements, [])
     |> assign(:bulk_confirmation, nil)
     |> assign(:pending_transaction_id, nil)
     |> assign(:import_account_id, nil)
     |> assign(:category_form, to_form(%{"name" => ""}))
     |> assign(:confirm_modal, nil)
     |> assign(:accounts, accounts)
     |> assign(:import_accounts, Enum.filter(accounts, & &1.accepts_import))
     |> assign(:categories, Categories.list_categories())
     |> assign(:filters, %{
       "search" => "",
       "account_id" => "",
       "category_id" => "",
       "date" => "",
       "amount" => "",
       "sort_order" => "desc",
       "type" => "",
       "month" => "",
       "year" => "",
       "unmatched_transfers" => ""
     })
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:return_to, nil)
     |> assign(:summary, %{
       current_balance: Decimal.new("0"),
       income: Decimal.new("0"),
       expenses: Decimal.new("0"),
       month_name: ""
     })
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> assign(:unmatched_transfers_count, 0)
     |> allow_upload(:statement, accept: ~w(.csv .pdf), max_entries: 100)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {return_to, filters_param} = Map.pop(params, "return_to")

    filters = Map.merge(socket.assigns.filters, filters_param || %{})

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:return_to, return_to)
      |> assign(:page, 1)
      |> assign(:end_of_list?, false)
      |> calculate_summary()
      |> stream(:transactions, Transactions.list_transactions(map_filters(filters), 1),
        reset: true
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("unmark_reimbursable", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)

    # If it has a link key, we must clear it from both transactions in the pair
    if tx.reimbursement_link_key do
      # Ensure we get everything
      Transactions.list_transactions(%{"search" => "", "reimbursement_status" => ""})
      |> Enum.filter(&(&1.reimbursement_link_key == tx.reimbursement_link_key))
      |> Enum.each(fn t ->
        Transactions.update_transaction(t, %{
          reimbursement_status: nil,
          reimbursement_link_key: nil
        })
      end)

      {:noreply,
       socket
       |> put_flash(:info, "Vínculo de reembolso removido.")
       |> stream(
         :transactions,
         Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
         reset: true
       )}
    else
      {:ok, updated} =
        Transactions.update_transaction(tx, %{
          reimbursement_status: nil,
          reimbursement_link_key: nil
        })

      {:noreply, stream_insert(socket, :transactions, updated)}
    end
  end

  @impl true
  def handle_event("mark_reimbursable", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, updated} = Transactions.update_transaction(tx, %{reimbursement_status: "pending"})
    {:noreply, stream_insert(socket, :transactions, updated)}
  end

  @impl true
  def handle_event("open_reimbursement_link", %{"id" => id}, socket) do
    credit_tx = Transactions.get_transaction!(id)

    {:noreply,
     socket
     |> assign(:show_reimbursement_modal, true)
     |> assign(:reimbursement_credit, credit_tx)
     |> assign(:reimbursement_search, "")
     |> update_reimbursement_linker_list()}
  end

  @impl true
  def handle_event("reimbursement_search_change", %{"value" => search}, socket) do
    {:noreply,
     socket |> assign(:reimbursement_search, search) |> update_reimbursement_linker_list()}
  end

  @impl true
  def handle_event("link_reimbursement", %{"expense-id" => expense_id}, socket) do
    credit_tx = socket.assigns.reimbursement_credit
    expense_tx = Transactions.get_transaction!(expense_id)
    link_key = Ecto.UUID.generate()

    # Category Inheritance Logic:
    # Use the expense category if it exists, otherwise use credit's, otherwise nil
    final_category_id = expense_tx.category_id || credit_tx.category_id

    # Update both transactions
    {:ok, _} =
      Transactions.update_transaction(expense_tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        category_id: final_category_id
      })

    {:ok, _} =
      Transactions.update_transaction(credit_tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        category_id: final_category_id
      })

    {:noreply,
     socket
     |> assign(:show_reimbursement_modal, false)
     |> put_flash(:info, "Reembolso vinculado e categorizado!")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("open_transfer_link", %{"id" => id}, socket) do
    origin_tx = Transactions.get_transaction!(id)

    {:noreply,
     socket
     |> assign(:show_transfer_modal, true)
     |> assign(:transfer_origin, origin_tx)
     |> update_transfer_linker_list()}
  end

  @impl true
  def handle_event("link_transfer", %{"pair-id" => pair_id}, socket) do
    origin_tx = socket.assigns.transfer_origin
    pair_tx = Transactions.get_transaction!(pair_id)
    transfer_key = Ecto.UUID.generate()

    # Update both transactions with the same key
    {:ok, _} = Transactions.update_transaction(origin_tx, %{transfer_key: transfer_key})
    {:ok, _} = Transactions.update_transaction(pair_tx, %{transfer_key: transfer_key})

    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> put_flash(:info, "Transferência vinculada com sucesso!")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("open_import", _params, socket) do
    {:noreply, assign(socket, :show_import_modal, true)}
  end

  @impl true
  def handle_event("open_quick_category", %{"name" => name, "id" => tx_id}, socket) do
    suggested_name = name |> String.split(" ") |> Enum.map(&String.capitalize/1) |> Enum.join(" ")

    {:noreply,
     socket
     |> assign(:show_quick_category_modal, true)
     |> assign(:pending_transaction_id, tx_id)
     |> assign(:category_form, to_form(%{"name" => suggested_name}))}
  end

  @impl true
  def handle_event("open_quick_transfer", _params, socket) do
    origin = socket.assigns.transfer_origin

    form_data = %{
      "date" => origin.date,
      "amount" => Decimal.mult(origin.amount, -1),
      "description" => origin.description
    }

    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, true)
     |> assign(:quick_transfer_form, to_form(form_data))}
  end

  @impl true
  def handle_event(
        "save_quick_transfer",
        %{
          "account_id" => target_account_id,
          "description" => description,
          "date" => date,
          "amount" => amount
        },
        socket
      ) do
    origin_tx = socket.assigns.transfer_origin
    transfer_key = Ecto.UUID.generate()

    # 1. Update origin transaction
    {:ok, origin_tx} = Transactions.update_transaction(origin_tx, %{transfer_key: transfer_key})

    # 2. Create target transaction
    # Find the transfer category ID
    transfer_category = Categories.get_category_by_slug("transfer")

    {:ok, pair_tx} =
      Transactions.create_transaction(%{
        account_id: target_account_id,
        category_id: transfer_category.id,
        description: description,
        date: date,
        amount: amount,
        transfer_key: transfer_key
      })

    # 3. Recalculate balances for both accounts/months
    CashLens.Accounting.calculate_monthly_balance(
      origin_tx.account_id,
      origin_tx.date.year,
      origin_tx.date.month
    )

    CashLens.Accounting.calculate_monthly_balance(
      pair_tx.account_id,
      pair_tx.date.year,
      pair_tx.date.month
    )

    {:noreply,
     socket
     |> assign(:show_quick_transfer_modal, false)
     |> put_flash(:info, "Par da transferência criado e vinculado!")
     |> calculate_summary()
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:show_quick_category_modal, false)
     |> assign(:show_reimbursement_modal, false)
     |> assign(:show_balance_correction, false)
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> assign(:ai_result, nil)
     |> assign(:ai_loading, false)
     |> assign(:confirm_modal, nil)
     |> assign(:bulk_confirmation, nil)}
  end

  @impl true
  def handle_event(
        "update_category",
        %{"transaction_id" => id, "category_id" => category_id},
        socket
      ) do
    category_id = if category_id == "", do: nil, else: category_id

    case Transactions.update_transaction_category(id, category_id) do
      {:ok, updated_tx} ->
        socket = assign(socket, :pending_count, Transactions.count_pending_transactions())
        tx = Transactions.get_transaction!(updated_tx.id)

        # Check against database ignore patterns
        ignore_patterns = Transactions.list_bulk_ignore_patterns()

        should_skip_bulk =
          Enum.any?(ignore_patterns, fn p ->
            case Regex.compile(p.pattern) do
              {:ok, re} -> Regex.run(re, tx.description || "")
              _ -> false
            end
          end)

        bulk_items =
          if category_id && !should_skip_bulk do
            Transactions.list_transactions(%{"search" => tx.description})
            |> Enum.reject(&(&1.id == tx.id or &1.category_id == category_id))
          else
            []
          end

        socket =
          if Enum.any?(bulk_items) do
            cat = Enum.find(socket.assigns.categories, &(&1.id == category_id))

            assign(socket, :bulk_confirmation, %{
              items: bulk_items,
              category_id: category_id,
              category_name: cat.name,
              description: tx.description
            })
          else
            socket
          end

        if matches_filters?(tx, socket.assigns.filters),
          do: {:noreply, stream_insert(socket, :transactions, tx)},
          else: {:noreply, stream_delete(socket, :transactions, tx)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Falha ao atualizar")}
    end
  end

  @impl true
  def handle_event("save_quick_category", %{"name" => name, "parent_id" => parent_id}, socket) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "_")
    parent_id = if parent_id == "", do: nil, else: parent_id

    case Categories.create_category(%{name: name, slug: slug, parent_id: parent_id}) do
      {:ok, category} ->
        Transactions.update_transaction_category(
          socket.assigns.pending_transaction_id,
          category.id
        )

        tx = Transactions.get_transaction!(socket.assigns.pending_transaction_id)

        socket =
          socket
          |> assign(:show_quick_category_modal, false)
          |> assign(:categories, Categories.list_categories())
          |> assign(:pending_count, Transactions.count_pending_transactions())
          |> put_flash(:info, "Categoria criada!")

        # Check against database ignore patterns
        ignore_patterns = Transactions.list_bulk_ignore_patterns()

        should_skip_bulk =
          Enum.any?(ignore_patterns, fn p ->
            case Regex.compile(p.pattern) do
              {:ok, re} -> Regex.run(re, tx.description || "")
              _ -> false
            end
          end)

        bulk_items =
          if !should_skip_bulk do
            Transactions.list_transactions(%{"search" => tx.description})
            |> Enum.reject(&(&1.id == tx.id or &1.category_id == category.id))
          else
            []
          end

        socket =
          if Enum.any?(bulk_items),
            do:
              assign(socket, :bulk_confirmation, %{
                items: bulk_items,
                category_id: category.id,
                category_name: category.name,
                description: tx.description
              }),
            else: socket

        if matches_filters?(tx, socket.assigns.filters),
          do: {:noreply, stream_insert(socket, :transactions, tx)},
          else: {:noreply, stream_delete(socket, :transactions, tx)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Erro ao criar.")}
    end
  end

  @impl true
  def handle_event("apply_bulk_category", _params, socket) do
    %{items: items, category_id: category_id} = socket.assigns.bulk_confirmation

    Enum.each(items, fn item -> Transactions.update_transaction_category(item.id, category_id) end)

    {:noreply,
     socket
     |> assign(:bulk_confirmation, nil)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> put_flash(:info, "Categorizado em massa!")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("auto_categorize_all", _params, socket) do
    Transactions.reapply_auto_categorization()

    {:noreply,
     socket
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> put_flash(:info, "Regras aplicadas!")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("apply_filters", params, socket) do
    valid_keys = Map.keys(socket.assigns.filters)
    safe_params = Map.take(params, valid_keys)
    new_filters = Map.merge(socket.assigns.filters, safe_params)

    txs = Transactions.list_transactions(map_filters(new_filters), 1)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, txs, reset: true)}
  end

  @impl true
  def handle_event("toggle_sort", _params, socket) do
    new_order = if socket.assigns.filters["sort_order"] == "desc", do: "asc", else: "desc"
    new_filters = Map.put(socket.assigns.filters, "sort_order", new_order)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    today = Date.utc_today()

    filters = %{
      "search" => "",
      "account_id" => "",
      "category_id" => "",
      "date" => "",
      "amount" => "",
      "sort_order" => "desc",
      "type" => "",
      "month" => "#{today.month}",
      "year" => "#{today.year}",
      "unmatched_transfers" => ""
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("toggle_unmatched", _params, socket) do
    new_val = if socket.assigns.filters["unmatched_transfers"] == "true", do: "", else: "true"
    new_filters = Map.put(socket.assigns.filters, "unmatched_transfers", new_val)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("prev_month", _params, socket) do
    today = Date.utc_today()

    m =
      if socket.assigns.filters["month"] == "",
        do: today.month,
        else: String.to_integer(socket.assigns.filters["month"])

    y =
      if socket.assigns.filters["year"] == "",
        do: today.year,
        else: String.to_integer(socket.assigns.filters["year"])

    {new_m, new_y} = if m == 1, do: {12, y - 1}, else: {m - 1, y}

    new_filters =
      socket.assigns.filters
      |> Map.put("month", "#{new_m}")
      |> Map.put("year", "#{new_y}")

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("next_month", _params, socket) do
    today = Date.utc_today()

    m =
      if socket.assigns.filters["month"] == "",
        do: today.month,
        else: String.to_integer(socket.assigns.filters["month"])

    y =
      if socket.assigns.filters["year"] == "",
        do: today.year,
        else: String.to_integer(socket.assigns.filters["year"])

    {new_m, new_y} = if m == 12, do: {1, y + 1}, else: {m + 1, y}

    new_filters =
      socket.assigns.filters
      |> Map.put("month", "#{new_m}")
      |> Map.put("year", "#{new_y}")

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("toggle_pending", _params, socket) do
    new_category_id = if socket.assigns.filters["category_id"] == "nil", do: "", else: "nil"
    new_filters = Map.put(socket.assigns.filters, "category_id", new_category_id)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("toggle_type", %{"type" => type}, socket) do
    new_type = if socket.assigns.filters["type"] == type, do: "", else: type
    new_filters = Map.put(socket.assigns.filters, "type", new_type)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> calculate_summary()
     |> stream(:transactions, Transactions.list_transactions(map_filters(new_filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    if socket.assigns.end_of_list? do
      {:noreply, socket}
    else
      next_page = socket.assigns.page + 1
      items = Transactions.list_transactions(map_filters(socket.assigns.filters), next_page)

      {:noreply,
       socket
       |> assign(:page, next_page)
       |> assign(:end_of_list?, Enum.empty?(items))
       |> stream_insert_many(:transactions, items)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("confirm_delete_all", _params, socket) do
    confirm = %{action: JS.push("delete_all")}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    transaction = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.delete_transaction(transaction)

    {:noreply,
     socket
     |> assign(:confirm_modal, nil)
     |> stream_delete(:transactions, transaction)
     |> assign(:pending_count, Transactions.count_pending_transactions())}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    Transactions.delete_all_transactions()

    {:noreply,
     socket
     |> assign(:confirm_modal, nil)
     |> stream(:transactions, [], reset: true)
     |> assign(:pending_count, 0)}
  end

  @impl true
  def handle_event("validate_import", %{"account_id" => account_id}, socket) do
    {:noreply, assign(socket, :import_account_id, account_id)}
  end

  @impl true
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_import", %{"account_id" => account_id}, socket) do
    account = Accounts.get_account!(account_id)
    parser_type = account.parser_type

    all_affected =
      consume_uploaded_entries(socket, :statement, fn %{path: path}, _entry ->
        content = File.read!(path)

        # If it's a PDF, we try to extract text using a system tool (pdftotext)
        content =
          if String.ends_with?(path, ".pdf") or parser_type == "sem_parar_pdf" do
            case System.cmd("pdftotext", ["-layout", path, "-"]) do
              {text, 0} -> text
              # Fallback to raw (likely will fail parsing)
              _ -> content
            end
          else
            if String.valid?(content),
              do: content,
              else: :unicode.characters_to_binary(content, :latin1, :utf8)
          end

        case Ingestor.parse(content, parser_type) do
          {:error, reason} ->
            {:postpone, reason}

          transactions_data ->
            periods = process_transactions_data(transactions_data, account_id)
            {:ok, {periods, length(transactions_data)}}
        end
      end)

    {all_periods, total_count} =
      Enum.reduce(all_affected, {MapSet.new(), 0}, fn {periods, count}, {acc_p, acc_c} ->
        {MapSet.union(acc_p, periods), acc_c + count}
      end)

    all_periods
    |> MapSet.to_list()
    |> Enum.each(fn {acc_id, month, year} ->
      CashLens.Accounting.calculate_monthly_balance(acc_id, year, month)
    end)

    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> put_flash(:info, "Sucesso! #{total_count} transações importadas.")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  def handle_event("open_balance_correction", _params, socket) do
    current_balance = socket.assigns.summary.current_balance

    {:noreply,
     socket
     |> assign(:show_balance_correction, true)
     |> assign(:balance_diff, Decimal.new("0"))
     |> assign(
       :balance_correction_form,
       to_form(%{"new_balance" => Decimal.to_string(current_balance, :normal)})
     )}
  end

  @impl true
  def handle_event("update_diff", %{"value" => value}, socket) do
    # Robust parsing: handle empty strings or partial decimals
    # Decimal.parse returns {decimal, rest} or :error
    new_val =
      if value in ["", "-", ".", "-."],
        do: Decimal.new("0"),
        else:
          Decimal.parse(value)
          |> (case do
                {d, _} -> d
                _ -> Decimal.new("0")
              end)

    diff = Decimal.sub(new_val, socket.assigns.summary.current_balance)

    {:noreply,
     socket
     |> assign(:balance_diff, diff)
     |> assign(:balance_correction_form, to_form(%{"new_balance" => value}))}
  end

  @impl true
  def handle_event(
        "save_balance_correction",
        %{"new_balance" => new_balance, "adjustment_type" => type},
        socket
      ) do
    account_id = socket.assigns.filters["account_id"]
    new_val = Decimal.new(new_balance)
    current_val = socket.assigns.summary.current_balance
    diff = Decimal.sub(new_val, current_val)

    case type do
      "rendimentos" ->
        # Find or create "Rendimentos" category
        category =
          case Categories.get_category_by_slug("rendimentos") do
            nil ->
              {:ok, cat} =
                Categories.create_category(%{
                  name: "Rendimentos",
                  slug: "rendimentos",
                  type: "variable"
                })

              cat

            cat ->
              cat
          end

        today = Date.utc_today()

        Transactions.create_transaction(%{
          account_id: account_id,
          category_id: category.id,
          amount: diff,
          date: today,
          description: "Ajuste de Saldo (Rendimentos)"
        })

        # Recalculate balance for the current month
        CashLens.Accounting.calculate_monthly_balance(account_id, today.year, today.month)

      "ajuste_inicial" ->
        # Find oldest balance for this account
        oldest = CashLens.Accounting.get_oldest_balance_for_account(account_id)

        if oldest do
          new_initial = Decimal.add(oldest.initial_balance, diff)
          CashLens.Accounting.update_balance(oldest, %{initial_balance: new_initial})
          # Trigger global recalculation
          CashLens.Accounting.recalculate_all_balances()
        else
          # If no balance exists, update account base balance
          account = Accounts.get_account!(account_id)

          Accounts.update_account(account, %{
            balance: Decimal.add(account.balance || Decimal.new("0"), diff)
          })
        end
    end

    {:noreply,
     socket
     |> assign(:show_balance_correction, false)
     |> put_flash(:info, "Saldo ajustado com sucesso!")
     |> calculate_summary()
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info({event, _category}, socket)
      when event in [:category_created, :category_updated, :category_deleted] do
    {:noreply, assign(socket, :categories, Categories.list_categories())}
  end

  # Helpers
  defp matches_filters?(tx, filters) do
    mapped = map_filters(filters)

    transfer_category_id =
      case Categories.get_category_by_slug("transfer") do
        nil -> nil
        cat -> cat.id
      end

    category_match =
      case mapped["category_id"] do
        "" -> true
        "nil" -> is_nil(tx.category_id)
        id -> tx.category_id == id
      end

    search_match =
      if mapped["search"] == "",
        do: true,
        else:
          String.contains?(String.upcase(tx.description || ""), String.upcase(mapped["search"]))

    account_match =
      if mapped["account_id"] == "", do: true, else: tx.account_id == mapped["account_id"]

    type_match =
      case mapped["type"] do
        "" -> true
        "debit" -> Decimal.lt?(tx.amount, 0)
        "credit" -> Decimal.gt?(tx.amount, 0)
        _ -> true
      end

    unmatched_match =
      if mapped["unmatched_transfers"] == "true",
        do: is_nil(tx.transfer_key) && tx.category_id == transfer_category_id,
        else: true

    category_match && search_match && account_match && type_match && unmatched_match
  end

  defp update_transfer_linker_list(socket) do
    origin_tx = socket.assigns.transfer_origin
    target_amount = Decimal.mult(origin_tx.amount, -1)

    # 1. Broad search for opposite value transactions
    # Criteria: same absolute amount (opposite signal), no transfer_key, different account
    candidates =
      Transactions.list_transactions(%{"amount" => target_amount})
      |> Enum.filter(fn t ->
        is_nil(t.transfer_key) and
          t.id != origin_tx.id and
          t.account_id != origin_tx.account_id
      end)

    # 2. Sort by date proximity to origin_tx
    sorted =
      Enum.sort_by(candidates, fn t ->
        abs(Date.diff(t.date, origin_tx.date))
      end)

    assign(socket, :pending_transfers, Enum.take(sorted, 50))
  end

  defp update_reimbursement_linker_list(socket) do
    credit_tx = socket.assigns.reimbursement_credit
    target_amount = credit_tx.amount |> Decimal.abs() |> Decimal.round(2)
    search = socket.assigns.reimbursement_search

    # 1. EXHAUSTIVE GLOBAL SEARCH for exact value matches
    # We query the DB directly for ANY transaction with this amount that isn't linked
    exact_matches =
      Transactions.list_transactions(%{"amount" => Decimal.mult(target_amount, -1)}, 1, 100)
      |> Enum.filter(&is_nil(&1.reimbursement_link_key))

    # 2. CONTEXTUAL SEARCH (recent items or description match)
    filters = %{"amount_max" => -0.01}
    filters = if search != "", do: Map.put(filters, "search", search), else: filters
    recent_items = Transactions.list_transactions(filters, 1, 500)

    # Combine and deduplicate (by ID)
    all_pending =
      (exact_matches ++ recent_items)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(is_nil(&1.reimbursement_link_key) && &1.reimbursement_status != "paid"))

    # Sort logic: 
    # 1. Exact amount match (VALUE IS KING)
    # 2. Non-categorized (Secondary tie-breaker)
    # 3. Newest first
    sorted_pending =
      all_pending
      |> Enum.sort(fn a, b ->
        amount_a = Decimal.abs(a.amount) |> Decimal.round(2)
        amount_b = Decimal.abs(b.amount) |> Decimal.round(2)
        target = Decimal.round(target_amount, 2)

        exact_a = Decimal.eq?(amount_a, target)
        exact_b = Decimal.eq?(amount_b, target)
        pending_cat_a = is_nil(a.category_id)
        pending_cat_b = is_nil(b.category_id)

        cond do
          exact_a != exact_b -> exact_a
          pending_cat_a != pending_cat_b -> pending_cat_a
          true -> Date.compare(a.date, b.date) != :lt
        end
      end)
      |> Enum.take(50)

    assign(socket, :pending_reimbursements, sorted_pending)
  end

  defp stream_insert_many(socket, stream_name, items) do
    Enum.reduce(items, socket, fn item, acc -> stream_insert(acc, stream_name, item) end)
  end

  defp calculate_summary(socket) do
    filters = socket.assigns.filters
    mapped = map_filters(filters)
    summary = Transactions.get_monthly_summary(nil, mapped)

    unmatched_count =
      Transactions.list_transactions(Map.put(mapped, "unmatched_transfers", "true")) |> length()

    current_balance =
      if mapped["account_id"] not in ["", nil] do
        account = Enum.find(socket.assigns.accounts, &(&1.id == mapped["account_id"]))

        if account do
          latest_balance = CashLens.Accounting.get_latest_balance_for_account(account.id)
          if latest_balance, do: latest_balance.final_balance, else: account.balance
        else
          Decimal.new("0")
        end
      else
        latest_balances = CashLens.Accounting.list_latest_balances()
        all_accounts = socket.assigns.accounts

        Enum.map(all_accounts, fn account ->
          balance = Enum.find(latest_balances, &(&1.account_id == account.id))
          if(balance, do: balance.final_balance, else: account.balance)
        end)
        |> Enum.reduce(Decimal.new("0"), &Decimal.add(&1, &2))
      end

    month_name =
      summary.month
      |> Calendar.strftime("%B")
      |> translate_month()

    socket
    |> assign(:unmatched_transfers_count, unmatched_count)
    |> assign(:summary, %{
      current_balance: current_balance,
      income: summary.income,
      expenses: summary.expenses,
      month_name: month_name
    })
  end

  defp map_filters(filters) do
    %{
      "search" => filters["search"],
      "account_id" => filters["account_id"],
      "category_id" => filters["category_id"],
      "date" => filters["date"],
      "amount" => filters["amount"],
      "sort_order" => filters["sort_order"],
      "type" => filters["type"],
      "month" => filters["month"],
      "year" => filters["year"],
      "unmatched_transfers" => filters["unmatched_transfers"]
    }
  end

  defp translate_month(month) do
    months = %{
      "January" => "Janeiro",
      "February" => "Fevereiro",
      "March" => "Março",
      "April" => "Abril",
      "May" => "Maio",
      "June" => "Junho",
      "July" => "Julho",
      "August" => "Agosto",
      "September" => "Setembro",
      "October" => "Outubro",
      "November" => "Novembro",
      "December" => "Dezembro"
    }

    months[month] || month
  end

  defp process_transactions_data(transactions_data, account_id) do
    Enum.reduce(transactions_data, MapSet.new(), fn data, acc ->
      data
      |> Map.put(:account_id, account_id)
      |> CashLens.Transactions.AutoCategorizer.categorize()
      |> Transactions.create_transaction()

      acc = MapSet.put(acc, {account_id, data.date.month, data.date.year})
      description = String.upcase(data.description || "")

      cond do
        String.contains?(description, "BB MM OURO") ->
          case Accounts.get_account_by_name("BB MM Ouro") do
            nil -> acc
            a -> MapSet.put(acc, {a.id, data.date.month, data.date.year})
          end

        String.contains?(description, ["BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
          case Accounts.get_account_by_name("BB Rende Fácil") do
            nil -> acc
            a -> MapSet.put(acc, {a.id, data.date.month, data.date.year})
          end

        true ->
          acc
      end
    end)
  end
end
