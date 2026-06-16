defmodule CashLensWeb.TransactionLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.Transactions
  alias CashLens.Transactions.CategorySuggester

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
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> assign(:show_notes_modal, false)
     |> assign(:transfer_pair_view, nil)
     |> assign(:editing_transaction, nil)
     |> assign(:transfer_origin, nil)
     |> assign(:pending_transfers, [])
     |> assign(:quick_transfer_form, to_form(%{}))
     |> assign(:reimbursement_credit, nil)
     |> assign(:reimbursement_search, "")
     |> assign(:pending_reimbursements, [])
     |> assign(:bulk_confirmation, nil)
     |> assign(:bulk_selected_ids, MapSet.new())
     |> assign(:pending_transaction_id, nil)
     |> assign(:import_account_id, nil)
     |> assign(
       :category_form,
       to_form(Categories.change_category(%Category{default_reimbursable: false}))
     )
     |> assign(:quick_category_parent, nil)
     |> assign(:auto_categorizing, false)
     |> assign(:filtered_count, nil)
     |> assign(:filters_active?, false)
     |> assign(:summary, %{income: Decimal.new("0"), expenses: Decimal.new("0")})
     |> assign(:transfer_pairs, %{})
     |> assign(:confirm_modal, nil)
     |> assign(:accounts, accounts)
     |> assign(:import_accounts, Enum.filter(accounts, & &1.accepts_import))
     |> assign(:categories, Categories.list_categories())
     |> assign(:filters, default_filters())
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:return_to, nil)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> assign(:unmatched_transfers_count, 0)
     |> assign(:installment_groups, CashLens.Installments.list_installment_groups())
     |> assign_transfer_category_id()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {return_to, params} = Map.pop(params, "return_to")
    {open_import, filters_param} = Map.pop(params, "open_import")

    filters = Map.merge(socket.assigns.filters, filters_param || %{})

    txs = Transactions.list_transactions(map_filters(filters), 1)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:return_to, return_to)
      |> assign(:show_import_modal, open_import == "true")
      |> assign(:page, 1)
      |> assign(:end_of_list?, false)
      |> assign(:transfer_pairs, %{})
      |> calculate_summary()
      |> load_transfer_pairs(txs)
      |> stream(:transactions, txs, reset: true)

    {:noreply, socket}
  end

  defp assign_transfer_category_id(socket) do
    id =
      case Categories.get_category_by_slug("transfer") do
        nil -> nil
        cat -> cat.id
      end

    assign(socket, :transfer_category_id, id)
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
       |> put_flash(:success, "Vínculo de reembolso removido.")
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

      {:noreply, stream_insert(socket, :transactions, annotate_one(updated))}
    end
  end

  @impl true
  def handle_event("link_installment", %{"id" => id, "group_id" => group_id}, socket) do
    tx = Transactions.get_transaction!(id)
    group = CashLens.Installments.get_group_with_progress(group_id)

    case Transactions.update_transaction(tx, %{
           installment_group_id: group_id,
           installment_number: group.paid_count + 1
         }) do
      {:ok, updated_tx} ->
        # Reload so the installment_group association is preloaded for rendering.
        {:noreply,
         socket
         |> put_flash(:success, "Vinculado a #{group.description_pattern}!")
         |> stream_insert(
           :transactions,
           annotate_one(Transactions.get_transaction!(updated_tx.id))
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Falha ao vincular.")}
    end
  end

  @impl true
  def handle_event("unlink_installment", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)

    {:ok, updated_tx} =
      Transactions.update_transaction(tx, %{
        installment_group_id: nil,
        installment_number: nil
      })

    {:noreply, stream_insert(socket, :transactions, annotate_one(updated_tx))}
  end

  @impl true
  def handle_event("mark_reimbursable", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, updated} = Transactions.update_transaction(tx, %{reimbursement_status: "pending"})
    {:noreply, stream_insert(socket, :transactions, annotate_one(updated))}
  end

  @impl true
  def handle_event("open_reimbursement_link", %{"id" => id}, socket) do
    credit_tx = Transactions.get_transaction!(id)

    {:noreply,
     socket
     |> assign(:show_reimbursement_modal, true)
     |> assign(:reimbursement_credit, credit_tx)}
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
  def handle_event("open_notes", %{"id" => id}, socket) do
    transaction = Transactions.get_transaction!(id)

    {:noreply,
     socket
     |> assign(:show_notes_modal, true)
     |> assign(:editing_transaction, transaction)}
  end

  @impl true
  def handle_event("save_notes", %{"tx_id" => id, "notes" => notes}, socket) do
    transaction = Transactions.get_transaction!(id)

    case Transactions.update_transaction(transaction, %{notes: notes}) do
      {:ok, updated_tx} ->
        {:noreply,
         socket
         |> assign(:show_notes_modal, false)
         |> assign(:editing_transaction, nil)
         |> put_flash(:success, "Notas atualizadas!")
         |> stream_insert(:transactions, annotate_one(updated_tx))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Falha ao atualizar notas.")}
    end
  end

  @impl true
  def handle_event("open_import", _params, socket) do
    {:noreply, assign(socket, :show_import_modal, true)}
  end

  @impl true
  def handle_event("open_quick_category", %{"name" => name, "id" => tx_id}, socket) do
    suggested_name = name |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)
    new_category = %Category{name: suggested_name, default_reimbursable: false}

    {:noreply,
     socket
     |> assign(:show_quick_category_modal, true)
     |> assign(:pending_transaction_id, tx_id)
     |> assign(:quick_category_parent, nil)
     |> assign(:category_form, to_form(Categories.change_category(new_category)))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:show_quick_category_modal, false)
     |> assign(:show_reimbursement_modal, false)
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> assign(:show_notes_modal, false)
     |> assign(:editing_transaction, nil)
     |> assign(:ai_result, nil)
     |> assign(:ai_loading, false)
     |> assign(:confirm_modal, nil)
     |> assign(:transfer_pair_view, nil)
     |> assign(:bulk_confirmation, nil)
     |> assign(:bulk_selected_ids, MapSet.new())}
  end

  @impl true
  def handle_event("open_transfer_pair", %{"key" => key}, socket) do
    pair =
      case Transactions.get_transfer_pairs([key]) do
        %{^key => txs} -> Enum.sort_by(txs, &Decimal.to_float(&1.amount))
        _ -> []
      end

    if pair == [] do
      {:noreply, put_flash(socket, :error, "Par de transferência não encontrado.")}
    else
      {:noreply, assign(socket, :transfer_pair_view, pair)}
    end
  end

  @impl true
  def handle_event("unlink_transfer_pair", %{"key" => key}, socket) do
    pair = Transactions.get_transfer_pairs([key]) |> Map.get(key, [])
    Transactions.unlink_transfer_pair(key)

    # Pairing affects each account's balance split, so rebuild the affected chains.
    pair
    |> Enum.map(& &1.account_id)
    |> Enum.uniq()
    |> Enum.each(&CashLens.Accounting.rebuild_account_balances/1)

    socket =
      pair
      |> Enum.reduce(socket, fn tx, acc ->
        stream_update_transaction(acc, Transactions.get_transaction!(tx.id))
      end)
      |> assign(:transfer_pair_view, nil)
      |> put_flash(:success, "Transferência desvinculada.")

    {:noreply, socket}
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
        # Explicit feedback so the action is never silent — especially under the
        # "Pendentes" filter, where a just-categorized row correctly leaves the list.
        flash_msg =
          if category_id,
            do: "Categoria aplicada: #{category_name(socket, category_id)}.",
            else: "Categoria removida."

        socket =
          socket
          |> assign(:pending_count, Transactions.count_pending_transactions())
          |> calculate_summary()
          |> put_flash(:success, flash_msg)
          |> handle_bulk_suggestion(updated_tx, category_id)
          |> stream_update_transaction(updated_tx)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Falha ao atualizar categoria: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("apply_bulk_category", _params, socket) do
    %{items: items, category_id: category_id} = socket.assigns.bulk_confirmation
    selected_ids = socket.assigns.bulk_selected_ids

    selected_items = Enum.filter(items, &MapSet.member?(selected_ids, &1.id))
    Enum.each(selected_items, &Transactions.update_transaction_category(&1.id, category_id))

    {:noreply,
     socket
     |> assign(:bulk_confirmation, nil)
     |> assign(:bulk_selected_ids, MapSet.new())
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> calculate_summary()
     |> put_flash(:success, "#{length(selected_items)} transações categorizadas!")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_event("toggle_bulk_tx", %{"id" => id}, socket) do
    selected = socket.assigns.bulk_selected_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :bulk_selected_ids, selected)}
  end

  @impl true
  def handle_event("toggle_bulk_all", _params, socket) do
    items = socket.assigns.bulk_confirmation.items
    selected = socket.assigns.bulk_selected_ids

    new_selected =
      if MapSet.size(selected) == length(items),
        do: MapSet.new(),
        else: MapSet.new(items, & &1.id)

    {:noreply, assign(socket, :bulk_selected_ids, new_selected)}
  end

  @impl true
  def handle_event("auto_categorize_all", _params, socket) do
    send(self(), :do_auto_categorize)
    {:noreply, assign(socket, :auto_categorizing, true)}
  end

  @impl true
  def handle_event("apply_filters", %{"_target" => target} = params, socket) do
    valid_keys = Map.keys(socket.assigns.filters)

    # The category autocomplete <input> lives inside this phx-change form but has no
    # name, so its events fire apply_filters with _target ["undefined"]. Ignore any
    # change that didn't come from an actual filter field — otherwise it resets the
    # transaction stream (destroying the open dropdown) and can loop.
    case target do
      [field] when is_binary(field) ->
        if field in valid_keys,
          do: apply_filter_change(params, valid_keys, socket),
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("apply_filters", params, socket) do
    apply_filter_change(params, Map.keys(socket.assigns.filters), socket)
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
  def handle_event("clear_filter", %{"field" => field}, socket) do
    new_filters = Map.put(socket.assigns.filters, field, "")

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
    filters = default_filters()

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
  def handle_event("set_date_range", %{"date_from" => from, "date_to" => to}, socket) do
    new_filters =
      socket.assigns.filters
      |> Map.put("date_from", from)
      |> Map.put("date_to", to)
      |> Map.put("date", "")

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
  def handle_event("toggle_unmatched", _params, socket) do
    enabling = socket.assigns.filters["unmatched_transfers"] != "true"

    new_filters =
      socket.assigns.filters
      |> Map.put("unmatched_transfers", if(enabling, do: "true", else: ""))
      |> Map.put("type", "")
      |> Map.put("category_id", "")

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
    enabling = socket.assigns.filters["category_id"] != "nil"

    new_filters =
      socket.assigns.filters
      |> Map.put("category_id", if(enabling, do: "nil", else: ""))
      |> Map.put("type", "")
      |> Map.put("unmatched_transfers", "")
      |> Map.put("sort_order", if(enabling, do: "asc", else: "desc"))
      |> Map.put("month", "")
      |> Map.put("year", "")

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

    new_filters =
      socket.assigns.filters
      |> Map.put("type", new_type)
      |> Map.put("category_id", "")
      |> Map.put("unmatched_transfers", "")

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
       |> load_transfer_pairs(items)
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
     |> calculate_summary()
     |> assign(:pending_count, Transactions.count_pending_transactions())}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    Transactions.delete_all_transactions()

    {:noreply,
     socket
     |> assign(:confirm_modal, nil)
     |> stream(:transactions, [], reset: true)
     |> calculate_summary()
     |> assign(:pending_count, 0)}
  end

  defp apply_filter_change(params, valid_keys, socket) do
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
  def handle_info(:do_auto_categorize, socket) do
    Transactions.reapply_auto_categorization()

    {:noreply,
     socket
     |> assign(:auto_categorizing, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> calculate_summary()
     |> put_flash(:success, "Regras aplicadas!")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  def handle_info(:reimbursement_linked, socket) do
    {:noreply,
     socket
     |> assign(:show_reimbursement_modal, false)
     |> put_flash(:success, "Reembolso vinculado e categorizado!")
     |> calculate_summary()
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info(:close_transfer_modal, socket) do
    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)}
  end

  @impl true
  def handle_info({:transfer_linked, message}, socket) do
    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> put_flash(:success, message)
     |> calculate_summary()
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info({:category_created, category, target_transaction_id}, socket) do
    if target_transaction_id do
      process_category_created_with_tx(socket, category, target_transaction_id)
    else
      {:noreply, assign(socket, :categories, Categories.list_categories())}
    end
  end

  @impl true
  def handle_info(:close_import_modal, socket) do
    {:noreply, assign(socket, :show_import_modal, false)}
  end

  @impl true
  def handle_info({:import_file_start, index, total, filename}, socket) do
    send_update(CashLensWeb.TransactionLive.ImportModalComponent,
      id: "import-modal",
      progress_update: %{
        file_index: index,
        file_total: total,
        current_file: filename,
        current_file_lines: :parsing
      }
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_file_parsed, n_lines}, socket) do
    send_update(CashLensWeb.TransactionLive.ImportModalComponent,
      id: "import-modal",
      progress_update: %{current_file_lines: n_lines}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_file_done, cumulative_lines}, socket) do
    send_update(CashLensWeb.TransactionLive.ImportModalComponent,
      id: "import-modal",
      progress_update: %{lines_done: cumulative_lines, current_file_lines: nil}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_success, %{imported: count, failed: []}}, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> calculate_summary()
     |> put_flash(:success, "Sucesso! #{count} transações importadas.")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  def handle_info({:import_success, %{imported: count, failed: failed}}, socket) do
    failed_msg = Enum.map_join(failed, ", ", fn {desc, reason} -> "#{desc}: #{reason}" end)

    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> calculate_summary()
     |> put_flash(
       :info,
       "#{count} transações importadas. #{length(failed)} linhas ignoradas: #{failed_msg}"
     )
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info({:import_error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Erro na importação: #{reason}")}
  end

  @impl true
  def handle_info({event, _category}, socket)
      when event in [:category_created, :category_updated, :category_deleted] do
    {:noreply, assign(socket, :categories, Categories.list_categories())}
  end

  # Helpers
  defp process_category_created_with_tx(socket, category, target_transaction_id) do
    Transactions.update_transaction_category(target_transaction_id, category.id)
    tx = Transactions.get_transaction!(target_transaction_id)

    socket =
      socket
      |> assign(:show_quick_category_modal, false)
      |> assign(:categories, Categories.list_categories())
      |> assign(:pending_count, Transactions.count_pending_transactions())
      |> calculate_summary()
      |> put_flash(:success, "Categoria criada!")

    bulk_items = get_bulk_items_for_tx(tx, category.id)

    socket =
      if Enum.any?(bulk_items) do
        selected_ids = bulk_items |> Enum.filter(&is_nil(&1.category_id)) |> MapSet.new(& &1.id)

        socket
        |> assign(:bulk_confirmation, %{
          items: bulk_items,
          category_id: category.id,
          category_name: category.name,
          description: tx.description
        })
        |> assign(:bulk_selected_ids, selected_ids)
      else
        socket
      end

    socket =
      if matches_filters?(tx, socket.assigns.filters, socket.assigns.transfer_category_id),
        do: stream_insert(socket, :transactions, tx),
        else: stream_delete(socket, :transactions, tx)

    {:noreply, socket}
  end

  defp get_bulk_items_for_tx(tx, category_id) do
    ignore_patterns = Transactions.list_bulk_ignore_patterns()

    should_skip_bulk =
      Enum.any?(ignore_patterns, fn p ->
        case Regex.compile(p.pattern) do
          {:ok, re} -> Regex.run(re, tx.description || "")
          _ -> false
        end
      end)

    if should_skip_bulk do
      []
    else
      Transactions.list_transactions(%{"search" => tx.description})
      |> Enum.reject(&(&1.id == tx.id or &1.category_id == category_id))
    end
  end

  # Single-row convenience over CategorySuggester.annotate/1 so streamed rows
  # never lose their suggestion pill, whatever path re-inserts them.
  defp annotate_one(tx) do
    [tx] = CategorySuggester.annotate([tx])
    tx
  end

  defp stream_update_transaction(socket, tx) do
    tx = annotate_one(Transactions.get_transaction!(tx.id))

    if matches_filters?(tx, socket.assigns.filters, socket.assigns.transfer_category_id),
      do: stream_insert(socket, :transactions, tx),
      else: stream_delete(socket, :transactions, tx)
  end

  defp category_name(socket, category_id) do
    case Enum.find(socket.assigns.categories, &(&1.id == category_id)) do
      nil -> "categoria"
      cat -> Category.full_name(cat)
    end
  end

  defp handle_bulk_suggestion(socket, _tx, nil), do: socket

  defp handle_bulk_suggestion(socket, tx, category_id) do
    ignore_patterns = Transactions.list_bulk_ignore_patterns()

    if should_skip_bulk?(tx.description, ignore_patterns) do
      socket
    else
      bulk_items =
        Transactions.list_transactions_by_description(tx.description)
        |> Enum.reject(&(&1.id == tx.id or &1.category_id == category_id))

      if Enum.any?(bulk_items) do
        cat = Enum.find(socket.assigns.categories, &(&1.id == category_id))
        selected_ids = bulk_items |> Enum.filter(&is_nil(&1.category_id)) |> MapSet.new(& &1.id)

        socket
        |> assign(:bulk_confirmation, %{
          items: bulk_items,
          category_id: category_id,
          category_name: cat.name,
          description: tx.description
        })
        |> assign(:bulk_selected_ids, selected_ids)
      else
        socket
      end
    end
  end

  defp should_skip_bulk?(nil, _), do: true

  defp should_skip_bulk?(description, ignore_patterns) do
    Enum.any?(ignore_patterns, fn p ->
      case Regex.compile(p.pattern) do
        {:ok, re} -> Regex.match?(re, description)
        _ -> false
      end
    end)
  end

  defp matches_filters?(tx, filters, transfer_category_id) do
    mapped = map_filters(filters)

    category_match?(tx, mapped["category_id"]) &&
      search_match?(tx, mapped["search"]) &&
      account_match?(tx, mapped["account_id"]) &&
      type_match?(tx, mapped["type"]) &&
      unmatched_match?(tx, mapped["unmatched_transfers"], transfer_category_id)
  end

  defp category_match?(_tx, ""), do: true
  defp category_match?(tx, "nil"), do: is_nil(tx.category_id)
  defp category_match?(tx, id), do: tx.category_id == id

  defp search_match?(_tx, ""), do: true

  defp search_match?(tx, search) do
    String.contains?(String.upcase(tx.description || ""), String.upcase(search))
  end

  defp account_match?(_tx, ""), do: true
  defp account_match?(tx, account_id), do: tx.account_id == account_id

  defp type_match?(_tx, ""), do: true
  defp type_match?(tx, "debit"), do: Decimal.lt?(tx.amount, 0)
  defp type_match?(tx, "credit"), do: Decimal.gt?(tx.amount, 0)

  defp unmatched_match?(_tx, "false", _), do: true

  defp unmatched_match?(tx, "true", transfer_category_id) do
    is_nil(tx.transfer_key) && tx.category_id == transfer_category_id
  end

  defp unmatched_match?(_tx, _, _), do: true

  defp update_transfer_linker_list(socket) do
    origin_tx = socket.assigns.transfer_origin
    target_amount = Decimal.mult(origin_tx.amount, -1)

    transfer_cat = Categories.get_category_by_slug("transfer")
    transfer_cat_id = if transfer_cat, do: transfer_cat.id, else: nil

    # 1. Broad search for opposite value transactions
    # Criteria: same absolute amount (opposite signal), no transfer_key, different account, uncategorized or transfer
    candidates =
      Transactions.list_transactions(%{"amount" => target_amount})
      |> Enum.filter(fn t ->
        is_nil(t.transfer_key) and
          t.id != origin_tx.id and
          t.account_id != origin_tx.account_id and
          (is_nil(t.category_id) or t.category_id == transfer_cat_id)
      end)

    # 2. Sort by date proximity to origin_tx
    sorted =
      Enum.sort_by(candidates, fn t ->
        abs(Date.diff(t.date, origin_tx.date))
      end)

    assign(socket, :pending_transfers, Enum.take(sorted, 50))
  end

  defp stream_insert_many(socket, stream_name, items) do
    Enum.reduce(items, socket, fn item, acc -> stream_insert(acc, stream_name, item) end)
  end

  defp calculate_summary(socket) do
    mapped = map_filters(socket.assigns.filters)

    unmatched_count =
      Transactions.list_transactions(%{"unmatched_transfers" => "true"}) |> length()

    active_filter? =
      mapped["type"] != "" or mapped["category_id"] == "nil" or
        mapped["unmatched_transfers"] == "true"

    filtered_count = if active_filter?, do: Transactions.count_transactions(mapped), else: nil

    summary = Transactions.get_filtered_summary(mapped)

    socket
    |> assign(:unmatched_transfers_count, unmatched_count)
    |> assign(:filtered_count, filtered_count)
    |> assign(:filters_active?, filters_active?(socket.assigns.filters))
    |> assign(:summary, summary)
  end

  defp load_transfer_pairs(socket, transactions) do
    keys =
      transactions
      |> Enum.map(& &1.transfer_key)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    new_pairs = Transactions.get_transfer_pairs(keys)
    assign(socket, :transfer_pairs, Map.merge(socket.assigns.transfer_pairs, new_pairs))
  end

  defp default_filters do
    %{
      "search" => "",
      "account_id" => "",
      "category_id" => "",
      "date" => "",
      "date_from" => "",
      "date_to" => "",
      "amount" => "",
      "sort_order" => "desc",
      "type" => "",
      "month" => "",
      "year" => "",
      "unmatched_transfers" => ""
    }
  end

  # A filter is considered "active" when any field other than sort_order
  # has a non-empty value.
  defp filters_active?(filters) do
    filters
    |> Map.drop(["sort_order"])
    |> Map.values()
    |> Enum.any?(&(&1 not in [nil, ""]))
  end

  defp map_filters(filters) do
    %{
      "search" => filters["search"],
      "account_id" => filters["account_id"],
      "category_id" => filters["category_id"],
      "date" => filters["date"],
      "date_from" => filters["date_from"],
      "date_to" => filters["date_to"],
      "amount" => filters["amount"],
      "sort_order" => filters["sort_order"],
      "type" => filters["type"],
      "month" => filters["month"],
      "year" => filters["year"],
      "unmatched_transfers" => filters["unmatched_transfers"]
    }
  end
end
