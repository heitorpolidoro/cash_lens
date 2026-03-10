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
      <.header>
        Transações
        <:actions>
          <.link navigate={~p"/reimbursements"}>
            <button class="btn btn-outline border-base-300 text-primary">
              <.icon name="hero-banknotes" class="size-4 mr-1" /> Reembolsos
            </button>
          </.link>
          <button type="button" phx-click="auto_categorize_all" class="btn btn-outline btn-primary">
            <.icon name="hero-sparkles" class="size-4 mr-1" /> Auto-Categorizar
          </button>
          <button type="button" phx-click="confirm_delete_all" class="btn btn-error btn-outline">
            <.icon name="hero-trash" class="size-4 mr-1" /> Limpar Tudo
          </button>
          <button type="button" phx-click="open_import" class="btn btn-outline border-base-300">
            <.icon name="hero-arrow-up-tray" class="size-4 mr-1" /> Importar Extratos
          </button>
          <.link navigate={~p"/transactions/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="size-4 mr-1" /> Nova Transação
            </.button>
          </.link>
        </:actions>
      </.header>

      <!-- Tabela com Filtros -->
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <div class="overflow-x-auto rounded-t-2xl">
          <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <form id="transaction-filters" phx-change="apply_filters" class="m-0 p-0">
              <input type="hidden" name="sort_order" value={@filters["sort_order"]} />
              <tr>
                <th class="w-40">
                  <div class="flex flex-col gap-1">
                    <div class="flex items-center justify-between pr-2">
                      <span>Data</span>
                      <button type="button" phx-click="toggle_sort" class="btn btn-ghost btn-xs p-0 hover:bg-transparent" title="Alternar ordenação">
                        <.icon name={if @filters["sort_order"] == "desc", do: "hero-chevron-down", else: "hero-chevron-up"} class="size-4" />
                      </button>
                    </div>
                    <input type="date" name="date" value={@filters["date"]} class="input input-bordered input-xs font-normal w-full" />
                  </div>
                </th>
                <th><div class="flex flex-col gap-1"><span>Descrição</span><input type="text" name="search" value={@filters["search"]} placeholder="Buscar..." class="input input-bordered input-xs font-normal w-full" phx-debounce="300" /></div></th>
                <th class="w-32 text-right"><div class="flex flex-col gap-1"><span>Valor</span><input type="number" name="amount" value={@filters["amount"]} placeholder="0.00" step="any" class="input input-bordered input-xs font-normal w-full text-right" phx-debounce="300" /></div></th>
                <th class="w-48">
                  <div class="flex flex-col gap-1">
                    <div class="flex items-center justify-between pr-2">
                      <span>Categoria</span>
                      <button type="button" phx-click="toggle_pending" class={["btn btn-ghost btn-xs p-0 hover:bg-transparent relative", @filters["category_id"] == "nil" && "text-error animate-pulse"]} title="Filtrar pendentes">
                        <.icon name="hero-exclamation-triangle" class="size-4" />
                        <span :if={@pending_count > 0} class="absolute -top-1 -right-1 badge badge-error badge-xs text-[8px] p-1 min-h-0 h-3">{@pending_count}</span>
                      </button>
                    </div>
                    <select name="category_id" class="select select-bordered select-xs font-normal w-full">
                      <option value="">Todas</option>
                      <option value="nil" selected={@filters["category_id"] == "nil"}>Pendente</option>
                      <%= for category <- @categories do %>
                        <option value={category.id} selected={@filters["category_id"] == category.id}>{CashLens.Categories.Category.full_name(category)}</option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="w-40">
                  <div class="flex flex-col gap-1">
                    <span>Conta</span>
                    <select name="account_id" class="select select-bordered select-xs font-normal w-full">
                      <option value="">Todas</option>
                      <%= for account <- @accounts do %>
                        <option value={account.id} selected={@filters["account_id"] == account.id}>{account.name}</option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="w-24">
                  <div class="flex flex-col gap-1 items-center">
                    <span class="opacity-0">Reset</span>
                    <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-xs text-error p-0" title="Limpar filtros">
                      <.icon name="hero-x-circle" class="size-4" />
                    </button>
                  </div>
                </th>
              </tr>
            </form>
          </thead>
        </table>
        </div> <!-- End of overflow-x-auto wrapper for the header -->

        <table class="table table-zebra w-full text-xs border-t border-base-300">
          <tbody id="transactions" phx-update="stream" class="overflow-visible">
            <tr :for={{id, transaction} <- @streams.transactions} id={id} class="hover group border-b border-base-200 overflow-visible">
              <td class="whitespace-nowrap w-40">
                <div class="flex flex-col pl-4">
                  <span class="font-medium text-base-content">{format_date(transaction.date)}</span>
                  <span class="text-[10px] opacity-50">
                    {if transaction.time, do: format_time(transaction.time), else: "--:--"} — {format_weekday(transaction.date)}
                  </span>
                </div>
              </td>
              <td class="py-2 px-4">
                <div class="flex flex-col">
                  <div class="leading-relaxed font-medium">{transaction.description}</div>
                  <div :if={transaction.reimbursement_status} class="flex items-center gap-1 mt-1">
                    <div class={["badge badge-xs text-[8px] uppercase", 
                      transaction.reimbursement_status == "paid" && "badge-success",
                      transaction.reimbursement_status == "requested" && "badge-info",
                      transaction.reimbursement_status == "pending" && "badge-warning"
                    ]}>
                      Reembolso: {CashLensWeb.Formatters.translate_reimbursement_status(transaction.reimbursement_status)}
                    </div>
                  </div>
                </div>
              </td>
              <td class={"w-32 text-right font-bold #{if Decimal.lt?(transaction.amount, 0), do: "text-error", else: "text-success"}"}>
                {format_currency(transaction.amount)}
              </td>
              <td class="w-48 overflow-visible">
                <div class="flex items-center gap-1 relative overflow-visible">
                  <div id={"cat-select-#{transaction.id}"} phx-hook="CategoryAutocomplete" data-transaction-id={transaction.id} data-categories={Jason.encode!(Enum.map(@categories, &%{id: &1.id, name: CashLens.Categories.Category.full_name(&1)}))} class="relative w-40 overflow-visible" phx-click-stop>
                    <div class="flex items-center gap-1 group/cat">
                      <input type="text" placeholder={if transaction.category, do: CashLens.Categories.Category.full_name(transaction.category), else: "Pendente"} class={["input input-bordered input-xs w-full font-bold uppercase text-[9px] cursor-pointer", is_nil(transaction.category_id) && "bg-warning text-warning-content border-warning/50"]} />
                      <button :if={transaction.category_id} type="button" phx-click="update_category" phx-value-transaction_id={transaction.id} phx-value-category_id="" class="btn btn-ghost btn-xs p-0 text-error min-h-0 h-5 w-5 opacity-0 group-hover/cat:opacity-100 transition-opacity" title="Limpar Categoria">
                        <.icon name="hero-x-mark" class="size-3" />
                      </button>
                    </div>
                    <div class="dropdown-content hidden absolute z-[100] mt-1 w-64 bg-base-100 border border-base-300 rounded-xl shadow-2xl overflow-hidden max-h-60 overflow-y-auto">
                      <ul class="menu menu-compact p-1">
                        <li class="new-option border-b border-base-200 mb-1">
                          <button type="button" class="font-black text-primary hover:bg-primary/10"><.icon name="hero-plus-circle" class="size-4" /><span>Nova Categoria</span></button>
                        </li>
                      </ul>
                    </div>
                  </div>
                  <%= if transaction.category && transaction.category.slug == "transfer" do %>
                    <span title={if transaction.transfer_key, do: "Transferência vinculada", else: "Transferência pendente de vínculo"}>
                      <.icon :if={transaction.transfer_key} name="hero-link" class="size-3 text-primary" />
                      <.icon :if={!transaction.transfer_key} name="hero-exclamation-triangle" class="size-3 text-warning" />
                    </span>
                  <% end %>
                  <span :if={transaction.reimbursement_link_key} title="Reembolsado">
                    <.icon name="hero-shield-check" class="size-3 text-success" />
                  </span>
                </div>
              </td>
              <td class="w-40 text-xs opacity-60 px-4">{if transaction.account, do: transaction.account.name, else: "..."}</td>
              <td class="w-24 text-right pr-4">
                <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                  <button type="button" phx-click="ai_research" phx-value-id={transaction.id} class="btn btn-ghost btn-xs text-secondary" title="Pesquisar com IA">
                    <.icon name="hero-sparkles" class="size-3" />
                  </button>
                  <%= if transaction.reimbursement_status do %>
                    <button type="button" phx-click="unmark_reimbursable" phx-value-id={transaction.id} class="btn btn-ghost btn-xs text-error" title="Remover marcação de reembolso">
                      <.icon name="hero-x-circle" class="size-3" />
                    </button>
                  <% end %>

                  <%= if Decimal.lt?(transaction.amount, 0) && is_nil(transaction.reimbursement_status) do %>
                    <button type="button" phx-click="mark_reimbursable" phx-value-id={transaction.id} class="btn btn-ghost btn-xs text-primary" title="Marcar Reembolsável">
                      <.icon name="hero-banknotes" class="size-3" />
                    </button>
                  <% end %>
                  <%= if Decimal.gt?(transaction.amount, 0) && is_nil(transaction.reimbursement_link_key) do %>
                    <button type="button" phx-click="open_reimbursement_link" phx-value-id={transaction.id} class="btn btn-ghost btn-xs text-success" title="Este é um reembolso">
                      <.icon name="hero-arrow-path" class="size-3" />
                    </button>
                  <% end %>
                  <.link navigate={~p"/transactions/#{transaction}/edit"} class="btn btn-ghost btn-xs px-1" phx-click-stop><.icon name="hero-pencil" class="size-3" /></.link>
                  <button type="button" phx-click="confirm_delete" phx-value-id={transaction.id} phx-click-stop class="btn btn-ghost btn-xs text-error px-1"><.icon name="hero-trash" class="size-3" /></button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
        
        <div id="infinite-scroll-sentinel" phx-hook="InfiniteScroll" class="py-4 flex justify-center border-t border-base-200">
          <div :if={not @end_of_list?} class="loading loading-spinner loading-sm text-primary opacity-20"></div>
          <p :if={@end_of_list?} class="text-[10px] uppercase font-bold opacity-20">Fim da lista</p>
        </div>
      </div>
    </div>

    <!-- Modal de Vínculo de Reembolso -->
    <.modal :if={@show_reimbursement_modal} id="reimbursement-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-success">Vincular Reembolso</h2>
        <p class="text-xs opacity-60 mb-6">Selecione abaixo a despesa que foi coberta por este recebimento de {format_currency(@reimbursement_credit.amount)}.</p>
        <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
          <%= if Enum.empty?(@pending_reimbursements) do %>
            <div class="text-center py-10 opacity-40 italic">Nenhuma despesa pendente de reembolso encontrada.</div>
          <% end %>
          <%= for pending <- @pending_reimbursements do %>
            <button type="button" phx-click="link_reimbursement" phx-value-expense-id={pending.id} class="w-full text-left flex items-center justify-between p-4 border-2 border-base-300 rounded-2xl hover:border-success hover:bg-success/5 transition-all group">
              <div class="flex flex-col"><span class="text-[10px] font-bold uppercase opacity-50">{format_date(pending.date)} — {pending.account.name}</span><span class="font-black text-lg group-hover:text-success">{pending.description}</span></div>
              <div class="text-right"><span class="font-black text-lg text-error">{format_currency(pending.amount)}</span><div class="text-[8px] uppercase font-bold px-2 py-0.5 bg-base-200 rounded-full mt-1">Pendente</div></div>
            </button>
          <% end %>
        </div>
      </div>
    </.modal>

    <!-- Modal de Pesquisa IA -->
    <.modal :if={@ai_loading or @ai_result} id="ai-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <div class="flex items-center gap-3 mb-6">
          <div class={["w-12 h-12 rounded-full flex items-center justify-center", @ai_loading && "bg-primary/10 text-primary animate-pulse", @ai_result && @ai_result.content == "" && "bg-primary/10 text-primary animate-pulse", @ai_result && @ai_result.content != "" && "bg-secondary/10 text-secondary"]}>
            <.icon name="hero-sparkles" class="size-6" />
          </div>
          <h2 class="text-2xl font-black uppercase tracking-tighter text-secondary">{if @ai_loading or (@ai_result && @ai_result.content == ""), do: "IA Pesquisando...", else: "Pesquisa IA"}</h2>
        </div>
        <%= if @ai_loading or (@ai_result && @ai_result.content == "") do %>
          <div class="flex flex-col items-center justify-center py-12 space-y-4">
            <div class="loading loading-ring loading-lg text-primary"></div>
            <p class="text-xs font-bold uppercase opacity-40">Consultando a internet via Gemini...</p>
          </div>
        <% else %>
          <div class="prose prose-sm max-w-none bg-base-200/50 p-6 rounded-2xl border border-base-300">
            <p class="text-xs font-bold uppercase opacity-40 mb-2">Descrição Analisada:</p>
            <p class="font-black text-lg mb-6 italic">"{@ai_result.description}"</p>
            <div class="divider">Resultado da Pesquisa</div>
            <div id="ai-content-renderer" phx-hook="MarkdownRenderer" data-content={@ai_result.content} class="text-base-content leading-relaxed">
              <!-- Content rendered via JS Hook -->
            </div>
          </div>
          <div class="flex justify-end mt-8">
            <button 
              phx-click="close_modal" 
              disabled={@ai_loading}
              class={["btn btn-secondary btn-lg w-full rounded-2xl shadow-xl shadow-secondary/20 font-black", @ai_loading && "btn-disabled opacity-50"]}
            >
              {if @ai_loading, do: "Aguarde a IA concluir...", else: "Entendido"}
            </button>
          </div>
        <% end %>
      </div>
    </.modal>

    <!-- Modal de Importação -->
    <.modal :if={@show_import_modal} id="import-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter text-primary">Importar Extratos</h2>
        <form id="upload-form" phx-submit="save_import" phx-change="validate_import" class="space-y-8">
          <div class="form-control w-full">
            <label class="label mb-2"><span class="label-text font-black text-lg">1. Selecione os Arquivos</span></label>
            <div class="flex items-center justify-center border-4 border-dashed border-base-300 rounded-3xl py-10 bg-base-200/30 hover:bg-base-200 transition-all cursor-pointer relative" phx-drop-target={@uploads.statement.ref}>
              <label class="cursor-pointer text-center w-full">
                <div :if={Enum.empty?(@uploads.statement.entries)} class="space-y-2">
                  <.icon name="hero-folder-plus" class="size-12 opacity-10 mx-auto" /><p class="text-xs opacity-40 font-bold uppercase">Clique nos botões abaixo ou arraste</p>
                  <div class="flex justify-center gap-2 mt-4">
                    <button type="button" class="btn btn-sm btn-outline border-base-300" phx-click={JS.dispatch("click", to: "input[data-phx-hook='Phoenix.LiveFileUpload']")}>Selecionar Arquivos</button>
                    <button type="button" class="btn btn-sm btn-outline border-base-300" phx-click={JS.dispatch("click", to: "#file-input-dir")}>Selecionar Pasta</button>
                  </div>
                </div>
                <div class="hidden"><.live_file_input upload={@uploads.statement} /><input type="file" id="file-input-dir" webkitdirectory directory phx-hook="DirectoryUpload" /></div>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 px-4 max-h-48 overflow-y-auto">
                  <%= for entry <- @uploads.statement.entries do %>
                    <div class="flex items-center gap-2 bg-primary/5 text-primary p-2 rounded-xl text-[10px] border border-primary/10">
                      <.icon name="hero-check-circle" class="size-4" /><span class="flex-1 text-left font-bold truncate">{entry.client_name}</span>
                      <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref} class="btn btn-ghost btn-xs min-h-0 h-6"><.icon name="hero-x-mark" class="size-3" /></button>
                    </div>
                  <% end %>
                </div>
              </label>
            </div>
          </div>
          <div :if={Enum.any?(@uploads.statement.entries)} class="form-control w-full space-y-4 animate-in slide-in-from-bottom-4">
            <label class="label"><span class="label-text font-black text-lg">2. Para qual conta vão estes arquivos?</span></label>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <%= for account <- @import_accounts do %>
                <label class="flex items-center gap-4 p-4 border-2 border-base-300 rounded-2xl cursor-pointer hover:bg-base-200 transition-all has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                  <input type="radio" name="account_id" value={account.id} class="radio radio-primary radio-md" required />
                  <div class="flex flex-col"><span class="font-black text-md">{account.name}</span><span class="text-[10px] opacity-50 font-bold uppercase">{account.bank}</span></div>
                </label>
              <% end %>
            </div>
          </div>
          <div :if={Enum.any?(@uploads.statement.entries)} class="flex justify-end pt-6 border-t border-base-200">
            <button type="submit" class="btn btn-primary btn-lg w-full rounded-2xl shadow-xl shadow-primary/20" phx-disable-with="Processando lote..."><.icon name="hero-bolt" class="size-5 mr-2" /> Finalizar e Importar Tudo</button>
          </div>
        </form>
      </div>
    </.modal>

    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6"><.icon name="hero-trash" class="size-10" /></div>
        <h2 class="text-2xl font-black mb-2">{@confirm_modal.title}</h2><p class="text-base-content/60 mb-10">{@confirm_modal.message}</p>
        <div class="flex flex-col sm:flex-row gap-3"><button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">Sim, Apagar</button><button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">Cancelar</button></div>
      </div>
    </.modal>

    <.modal :if={@show_quick_category_modal} id="quick-category-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter text-primary">Nova Categoria</h2>
        <.form :let={f} for={@category_form} id="quick-category-form" phx-submit="save_quick_category" class="space-y-6">
          <div class="space-y-4">
            <.input field={f[:name]} type="text" label="Nome da Categoria" placeholder="Ex: Netflix, Mercado..." required />
            <.input field={f[:parent_id]} type="select" label="Vincular a uma Categoria Pai? (Opcional)" options={Enum.map(@categories, &{CashLens.Categories.Category.full_name(&1), &1.id})} prompt="Nenhuma (Categoria Principal)" />
          </div>
          <div class="flex justify-end pt-4"><button type="submit" class="btn btn-primary btn-lg w-full rounded-2xl shadow-xl shadow-primary/20" phx-disable-with="Criando...">Criar e Aplicar</button></div>
        </.form>
      </div>
    </.modal>

    <.modal :if={@bulk_confirmation} id="bulk-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <div class="w-16 h-16 bg-primary/10 text-primary rounded-full flex items-center justify-center mb-6"><.icon name="hero-rectangle-stack" class="size-8" /></div>
        <h2 class="text-2xl font-black mb-2">Aplicar em massa?</h2>
        <p class="text-base-content/60 mb-6 text-sm">Encontrei mais <strong>{length(@bulk_confirmation.items)}</strong> transações com a mesma descrição ("{@bulk_confirmation.description}"). Deseja aplicar a categoria <strong>{@bulk_confirmation.category_name}</strong> em todas elas?</p>
        <div class="max-h-48 overflow-y-auto mb-8 border border-base-200 rounded-xl">
          <table class="table table-xs w-full">
            <thead class="bg-base-200/30"><tr><th>Data</th><th>Descrição</th><th class="text-right">Valor</th><th>Categoria Atual</th></tr></thead>
            <tbody class="opacity-70 text-[10px]">
              <%= for item <- @bulk_confirmation.items do %>
                <tr><td class="font-bold">{format_date(item.date)}</td><td class="max-w-[120px] truncate">{item.description}</td><td class="text-right">{format_currency(item.amount)}</td>
                  <td><%= if item.category do %><div class="badge badge-outline badge-xs text-[8px] uppercase">{item.category.name}</div><% else %><span class="opacity-30 italic">Pendente</span><% end %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <div class="flex flex-col sm:flex-row gap-3"><button phx-click="apply_bulk_category" class="btn btn-primary btn-lg flex-1 rounded-2xl shadow-xl shadow-primary/20">Sim, aplicar em todas</button><button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">Agora não</button></div>
      </div>
    </.modal>
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
     |> assign(:reimbursement_credit, nil)
     |> assign(:pending_reimbursements, [])
     |> assign(:ai_result, nil)
     |> assign(:ai_loading, false)
     |> assign(:bulk_confirmation, nil)
     |> assign(:pending_transaction_id, nil)
     |> assign(:category_form, to_form(%{"name" => ""}))
     |> assign(:confirm_modal, nil)
     |> assign(:accounts, accounts)
     |> assign(:import_accounts, Enum.filter(accounts, & &1.accepts_import))
     |> assign(:categories, Categories.list_categories())
     |> assign(:filters, %{"search" => "", "account_id" => "", "category_id" => "", "date" => "", "amount" => "", "sort_order" => "desc"})
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> stream(:transactions, Transactions.list_transactions())
     |> allow_upload(:statement, accept: ~w(.csv), max_entries: 100)}
  end

  @impl true
  def handle_event("ai_research", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    parent = self()
    Task.start(fn -> CashLens.AI.research_transaction_stream(tx.description, parent) end)
    {:noreply, socket |> assign(:ai_loading, true) |> assign(:ai_result, %{description: tx.description, content: ""})}
  end

  @impl true
  def handle_event("unmark_reimbursable", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    
    # If it has a link key, we must clear it from both transactions in the pair
    if tx.reimbursement_link_key do
      Transactions.list_transactions(%{"search" => "", "reimbursement_status" => ""}) # Ensure we get everything
      |> Enum.filter(& &1.reimbursement_link_key == tx.reimbursement_link_key)
      |> Enum.each(fn t -> 
        Transactions.update_transaction(t, %{reimbursement_status: nil, reimbursement_link_key: nil})
      end)
      
      {:noreply,
       socket
       |> put_flash(:info, "Vínculo de reembolso removido.")
       |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
    else
      {:ok, updated} = Transactions.update_transaction(tx, %{reimbursement_status: nil, reimbursement_link_key: nil})
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
    pending = Transactions.list_transactions(%{"reimbursement_status" => "pending"})
    {:noreply, socket |> assign(:show_reimbursement_modal, true) |> assign(:reimbursement_credit, credit_tx) |> assign(:pending_reimbursements, pending)}
  end

  @impl true
  def handle_event("link_reimbursement", %{"expense-id" => expense_id}, socket) do
    credit_tx = socket.assigns.reimbursement_credit
    expense_tx = Transactions.get_transaction!(expense_id)
    link_key = Ecto.UUID.generate()
    {:ok, _} = Transactions.update_transaction(expense_tx, %{reimbursement_status: "paid", reimbursement_link_key: link_key})
    {:ok, _} = Transactions.update_transaction(credit_tx, %{reimbursement_status: "paid", reimbursement_link_key: link_key})
    {:noreply, socket |> assign(:show_reimbursement_modal, false) |> put_flash(:info, "Reembolso vinculado!") |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
  end

  @impl true
  def handle_event("open_quick_category", %{"name" => name, "id" => tx_id}, socket) do
    suggested_name = name |> String.split(" ") |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
    {:noreply, socket |> assign(:show_quick_category_modal, true) |> assign(:pending_transaction_id, tx_id) |> assign(:category_form, to_form(%{"name" => suggested_name}))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:show_import_modal, false) |> assign(:show_quick_category_modal, false) |> assign(:show_reimbursement_modal, false) |> assign(:ai_result, nil) |> assign(:ai_loading, false) |> assign(:confirm_modal, nil) |> assign(:bulk_confirmation, nil)}
  end

  @impl true
  def handle_event("update_category", %{"transaction_id" => id, "category_id" => category_id}, socket) do
    category_id = if category_id == "", do: nil, else: category_id
    case Transactions.update_transaction_category(id, category_id) do
      {:ok, updated_tx} ->
        socket = assign(socket, :pending_count, Transactions.count_pending_transactions())
        tx = Transactions.get_transaction!(updated_tx.id)
        bulk_items = if category_id, do: Transactions.list_transactions(%{"search" => tx.description}) |> Enum.reject(&(&1.id == tx.id or &1.category_id == category_id)), else: []
        socket = if Enum.any?(bulk_items) do
          cat = Enum.find(socket.assigns.categories, & &1.id == category_id)
          assign(socket, :bulk_confirmation, %{items: bulk_items, category_id: category_id, category_name: cat.name, description: tx.description})
        else
          socket
        end
        if matches_filters?(tx, socket.assigns.filters), do: {:noreply, stream_insert(socket, :transactions, tx)}, else: {:noreply, stream_delete(socket, :transactions, tx)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Falha ao atualizar")}
    end
  end

  @impl true
  def handle_event("save_quick_category", %{"name" => name, "parent_id" => parent_id}, socket) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "_")
    parent_id = if parent_id == "", do: nil, else: parent_id
    case Categories.create_category(%{name: name, slug: slug, parent_id: parent_id}) do
      {:ok, category} ->
        Transactions.update_transaction_category(socket.assigns.pending_transaction_id, category.id)
        tx = Transactions.get_transaction!(socket.assigns.pending_transaction_id)
        socket = socket |> assign(:show_quick_category_modal, false) |> assign(:categories, Categories.list_categories()) |> assign(:pending_count, Transactions.count_pending_transactions()) |> put_flash(:info, "Categoria criada!")
        bulk_items = Transactions.list_transactions(%{"search" => tx.description}) |> Enum.reject(&(&1.id == tx.id or &1.category_id == category.id))
        socket = if Enum.any?(bulk_items), do: assign(socket, :bulk_confirmation, %{items: bulk_items, category_id: category.id, category_name: category.name, description: tx.description}), else: socket
        if matches_filters?(tx, socket.assigns.filters), do: {:noreply, stream_insert(socket, :transactions, tx)}, else: {:noreply, stream_delete(socket, :transactions, tx)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Erro ao criar.")}
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
     |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
  end

  @impl true
  def handle_event("auto_categorize_all", _params, socket) do
    Transactions.reapply_auto_categorization()
    {:noreply, socket |> assign(:pending_count, Transactions.count_pending_transactions()) |> put_flash(:info, "Regras aplicadas!") |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
  end

  @impl true
  def handle_event("apply_filters", params, socket) do
    {:noreply, socket |> assign(:filters, params) |> assign(:page, 1) |> assign(:end_of_list?, false) |> stream(:transactions, Transactions.list_transactions(params, 1), reset: true)}
  end

  @impl true
  def handle_event("toggle_sort", _params, socket) do
    new_order = if socket.assigns.filters["sort_order"] == "desc", do: "asc", else: "desc"
    new_filters = Map.put(socket.assigns.filters, "sort_order", new_order)
    {:noreply, socket |> assign(:filters, new_filters) |> assign(:page, 1) |> assign(:end_of_list?, false) |> stream(:transactions, Transactions.list_transactions(new_filters, 1), reset: true)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = %{"search" => "", "account_id" => "", "category_id" => "", "date" => "", "amount" => "", "sort_order" => "desc"}
    {:noreply, socket |> assign(:filters, filters) |> assign(:page, 1) |> assign(:end_of_list?, false) |> stream(:transactions, Transactions.list_transactions(filters, 1), reset: true)}
  end

  @impl true
  def handle_event("toggle_pending", _params, socket) do
    new_category_id = if socket.assigns.filters["category_id"] == "nil", do: "", else: "nil"
    new_filters = Map.put(socket.assigns.filters, "category_id", new_category_id)
    {:noreply, socket |> assign(:filters, new_filters) |> assign(:page, 1) |> assign(:end_of_list?, false) |> stream(:transactions, Transactions.list_transactions(new_filters, 1), reset: true)}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    if socket.assigns.end_of_list? do
      {:noreply, socket}
    else
      next_page = socket.assigns.page + 1
      new_transactions = Transactions.list_transactions(socket.assigns.filters, next_page)
      {:noreply, socket |> assign(:page, next_page) |> assign(:end_of_list?, Enum.empty?(new_transactions)) |> stream_insert_many(:transactions, new_transactions)}
    end
  end

  @impl true
  def handle_event("open_import", _params, socket), do: {:noreply, assign(socket, :show_import_modal, true)}

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket), do: {:noreply, cancel_upload(socket, :statement, ref)}

  @impl true
  def handle_event("confirm_delete_all", _params, socket) do
    confirm = %{title: "Limpar tudo?", message: "Você está prestes a apagar TODAS as transações do sistema.", action: "delete_all"}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{title: "Excluir transação?", message: "Deseja realmente apagar este registro?", action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    Transactions.delete_all_transactions()
    {:noreply, socket |> assign(:confirm_modal, nil) |> assign(:pending_count, 0) |> put_flash(:info, "Limpeza concluída.") |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    transaction = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.delete_transaction(transaction)
    {:noreply, socket |> assign(:confirm_modal, nil) |> assign(:pending_count, Transactions.count_pending_transactions()) |> stream_delete(:transactions, transaction)}
  end

  @impl true
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_import", %{"account_id" => account_id}, socket) do
    all_affected_periods = consume_uploaded_entries(socket, :statement, fn %{path: path}, entry ->
      content = File.read!(path)
      content = if String.valid?(content), do: content, else: :unicode.characters_to_binary(content, :latin1, :utf8)
      case Ingestor.parse(content, entry.client_name) do
        {:error, reason} -> {:postpone, reason}
        transactions_data ->
          periods = Enum.reduce(transactions_data, MapSet.new(), fn data, acc ->
            data |> Map.put(:account_id, account_id) |> CashLens.Transactions.AutoCategorizer.categorize() |> Transactions.create_transaction()
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
              true -> acc
            end
          end)
          {:ok, periods}
      end
    end)
    all_affected_periods |> List.flatten() |> Enum.reduce(MapSet.new(), fn set, acc -> MapSet.union(acc, set) end) |> MapSet.to_list() |> Enum.each(fn {acc_id, month, year} -> CashLens.Accounting.calculate_monthly_balance(acc_id, year, month) end)
    {:noreply, socket |> assign(:show_import_modal, false) |> assign(:page, 1) |> assign(:end_of_list?, false) |> assign(:pending_count, Transactions.count_pending_transactions()) |> put_flash(:info, "Importação concluída!") |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
  end

  @impl true
  def handle_info({:ai_chunk, chunk}, socket) do
    new_content = (socket.assigns.ai_result.content || "") <> chunk
    # Do NOT set ai_loading to false here, keep it true until ai_done
    {:noreply, 
     socket 
     |> update(:ai_result, &Map.put(&1, :content, new_content))}
  end

  @impl true
  def handle_info(:ai_done, socket) do
    {:noreply, assign(socket, :ai_loading, false)}
  end

  @impl true
  def handle_info({:ai_error, message}, socket) do
    {:noreply, socket |> assign(:ai_loading, false) |> update(:ai_result, &Map.put(&1, :content, message))}
  end

  @impl true
  def handle_info({event, _category}, socket) when event in [:category_created, :category_updated, :category_deleted] do
    {:noreply, assign(socket, :categories, Categories.list_categories())}
  end

  # Helpers
  defp matches_filters?(tx, filters) do
    category_match = case filters["category_id"] do
      "" -> true
      "nil" -> is_nil(tx.category_id)
      id -> tx.category_id == id
    end
    search_match = if filters["search"] == "", do: true, else: String.contains?(String.upcase(tx.description || ""), String.upcase(filters["search"]))
    account_match = if filters["account_id"] == "", do: true, else: tx.account_id == filters["account_id"]
    category_match && search_match && account_match
  end

  defp stream_insert_many(socket, stream_name, items) do
    Enum.reduce(items, socket, fn item, acc -> stream_insert(acc, stream_name, item) end)
  end
end
