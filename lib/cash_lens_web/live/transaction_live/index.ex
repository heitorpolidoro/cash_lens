defmodule CashLensWeb.TransactionLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.Pluggy.LivePreview
  alias CashLens.Pluggy.LivePreviewCache
  alias CashLens.Transactions
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.PluggyMatcher
  alias CashLens.Transactions.Transaction

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CashLens.PubSub, "categories")
    accounts = Accounts.list_accounts()

    {:ok,
     socket
     |> assign(:page_title, "Transações")
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
     |> assign(
       :category_form,
       to_form(Categories.change_category(%Category{default_reimbursable: false}))
     )
     |> assign(:quick_category_parent, nil)
     |> assign(:auto_categorizing, false)
     |> assign(:filtered_count, nil)
     |> assign(:filters_active?, false)
     |> assign(:summary, %{income: Decimal.new("0"), expenses: Decimal.new("0")})
     |> assign(:pluggy_error, nil)
     |> assign(:live_entries, [])
     |> assign(:transfer_pairs, %{})
     |> assign(:reimbursement_pairs, %{})
     |> assign(:reimbursement_pair_view, nil)
     |> assign(:confirm_modal, nil)
     |> assign(:accounts, accounts)
     |> assign(:categories, Categories.list_categories())
     |> assign(:filters, default_filters())
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:stream_loaded?, false)
     |> assign(:form_action, nil)
     |> assign(:form_transaction, nil)
     |> assign(:show_transaction, nil)
     |> assign(:return_to, nil)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> assign(:statement_health, Transactions.statement_health())
     |> assign(:installment_groups, CashLens.Installments.list_installment_groups())
     |> assign_transfer_category_id()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {return_to, params} = Map.pop(params, "return_to")
    # `:id` addresses the overlaid show/edit modal — it is never a filter.
    {id, filters_param} = Map.pop(params, "id")

    previous_filters = socket.assigns.filters

    filters =
      previous_filters
      |> Map.merge(filters_param || %{})
      # A month/year arriving in the URL must show up in the period select too.
      |> sync_period()

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:return_to, return_to)
      |> maybe_refresh_stream(filters, previous_filters)
      |> apply_action(socket.assigns.live_action, id)

    {:noreply, socket}
  end

  # Opening or closing a modal is a `live_patch`, and `handle_params` runs for
  # it exactly like it does for a filter deep link. Rebuilding the stream here
  # unconditionally would drop every page the user scrolled in and snap the
  # statement back to the top, so page 1 is only re-fetched on the first
  # `handle_params` after mount or when the URL actually changed the filters.
  defp maybe_refresh_stream(socket, filters, previous_filters) do
    if socket.assigns.stream_loaded? and filters == previous_filters do
      socket
    else
      socket
      |> refresh_transactions_page1(filters)
      |> assign(:stream_loaded?, true)
    end
  end

  defp apply_action(socket, :new, _id) do
    socket
    |> assign(:page_title, "Nova Transação")
    |> assign(:form_action, :new)
    |> assign(:form_transaction, %Transaction{date: Date.utc_today()})
    |> assign(:show_transaction, nil)
  end

  defp apply_action(socket, :edit, id) do
    transaction = Transactions.get_transaction!(id)

    socket
    |> assign(:page_title, "Editar Transação")
    |> assign(:form_action, :edit)
    |> assign(:form_transaction, transaction)
    |> assign(:accounts, with_account(socket.assigns.accounts, transaction))
    |> assign(:show_transaction, nil)
  end

  defp apply_action(socket, :show, id) do
    socket
    |> assign(:page_title, "Detalhes da Transação")
    |> assign(:form_action, nil)
    |> assign(:form_transaction, nil)
    |> assign(:show_transaction, Transactions.get_transaction!(id))
  end

  defp apply_action(socket, _index, _id) do
    socket
    |> assign(:page_title, "Transações")
    |> assign(:form_action, nil)
    |> assign(:form_transaction, nil)
    |> assign(:show_transaction, nil)
  end

  # A transaction may sit on a closed account that the select no longer lists;
  # without this the edit modal would silently re-point it somewhere else.
  defp with_account(accounts, %{account_id: nil}), do: accounts

  defp with_account(accounts, transaction) do
    if Enum.any?(accounts, &(&1.id == transaction.account_id)) do
      accounts
    else
      [Accounts.get_account!(transaction.account_id) | accounts]
    end
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
       |> refresh_transactions_page1(socket.assigns.filters)}
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
  def handle_event("sync_pluggy", _params, socket) do
    req_options = Application.get_env(:cash_lens, :pluggy_req_options, [])
    alias CashLens.Pluggy
    alias CashLens.Pluggy.Client

    case fetch_pluggy_credentials() do
      {:ok, client_id, client_secret} ->
        case Client.auth(client_id, client_secret, req_options) do
          {:ok, api_key} ->
            results =
              Enum.map(Pluggy.list_items(), fn item ->
                with {:ok, accounts} <- Client.list_accounts(api_key, item.item_id, req_options) do
                  Enum.each(accounts, fn account ->
                    Pluggy.upsert_account_link(item, %{
                      pluggy_account_id: account["id"],
                      pluggy_account_name: account["name"],
                      pluggy_account_type: account["type"],
                      pluggy_balance: account["balance"]
                    })
                  end)

                  {:ok, accounts}
                end
              end)

            ok_count = Enum.count(results, &match?({:ok, _}, &1))
            failed_count = length(results) - ok_count

            LivePreviewCache.refresh_now(live_preview_cache())

            items_count = length(Pluggy.list_items())

            {flash_kind, message} =
              cond do
                items_count == 0 ->
                  {:info, "Nenhum item Pluggy cadastrado."}

                failed_count > 0 ->
                  {:error,
                   "Sincronização com Pluggy concluída com erros (#{ok_count} ok, #{failed_count} falharam)."}

                true ->
                  {:success, "Pluggy sincronizado com sucesso."}
              end

            {:noreply,
             socket
             |> put_flash(flash_kind, message)
             |> refresh_transactions_page1(socket.assigns.filters)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Falha ao autenticar no Pluggy.")}
        end

      {:error, :missing_credentials} ->
        {:noreply,
         put_flash(socket, :error, "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados.")}
    end
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
  def handle_event("close_transaction_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/transactions")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
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
     |> assign(:reimbursement_pair_view, nil)
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
  def handle_event("open_reimbursement_pair", %{"key" => key}, socket) do
    pair =
      case Transactions.get_reimbursement_pairs([key]) do
        %{^key => txs} -> txs
        _ -> []
      end

    if pair == [] do
      {:noreply, put_flash(socket, :error, "Vínculo de reembolso não encontrado.")}
    else
      {:noreply, assign(socket, :reimbursement_pair_view, pair)}
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
          |> recalculate_summary()
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
     |> put_flash(:success, "#{length(selected_items)} transações categorizadas!")
     |> refresh_transactions_page1(socket.assigns.filters)}
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
     |> refresh_transactions_page1(new_filters)}
  end

  @impl true
  def handle_event("clear_filter", %{"field" => field}, socket) do
    new_filters = Map.put(socket.assigns.filters, field, "")

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> refresh_transactions_page1(new_filters)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> refresh_transactions_page1(filters)}
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
     |> refresh_transactions_page1(new_filters)}
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
     |> refresh_transactions_page1(new_filters)}
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
      |> sync_period()

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> refresh_transactions_page1(new_filters)}
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
      |> sync_period()

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> refresh_transactions_page1(new_filters)}
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
      |> sync_period()

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> refresh_transactions_page1(new_filters)}
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
     |> refresh_transactions_page1(new_filters)}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    if socket.assigns.end_of_list? do
      {:noreply, socket}
    else
      next_page = socket.assigns.page + 1

      items =
        Transactions.list_transactions(map_filters(socket.assigns.filters), next_page)
        |> annotate_pluggy_categories()

      # A short page means the last row has been reached — stop before issuing
      # an extra empty query when the sentinel scrolls into view again.
      {:noreply,
       socket
       |> assign(:page, next_page)
       |> assign(:end_of_list?, length(items) < page_size())
       |> load_transfer_pairs(items)
       |> load_reimbursement_pairs(items)
       |> stream_insert_many(:transactions, items)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{
      action: JS.push("delete", value: %{id: id}),
      transaction: Transactions.get_transaction!(id)
    }

    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("confirm_delete_all", _params, socket) do
    confirm = %{action: JS.push("delete_all"), transaction: nil}
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
     |> recalculate_summary()
     |> assign(:pending_count, Transactions.count_pending_transactions())}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    Transactions.delete_all_transactions()

    {:noreply,
     socket
     |> assign(:confirm_modal, nil)
     |> stream(:transactions, [], reset: true)
     # The stream reset also clears the live rows, so the summary must drop
     # their contribution too — hence plain `calculate_summary/1` here.
     |> assign(:live_entries, [])
     |> calculate_summary()
     |> assign(:pending_count, 0)}
  end

  defp apply_filter_change(params, valid_keys, socket) do
    safe_params = Map.take(params, valid_keys)

    new_filters =
      socket.assigns.filters
      |> Map.merge(safe_params)
      |> normalize_period(safe_params)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> refresh_transactions_page1(new_filters)}
  end

  @impl true
  def handle_info({:transaction_saved, transaction, action}, socket) do
    message =
      if action == :new,
        do: "Transação criada com sucesso",
        else: "Transação atualizada com sucesso"

    {:noreply,
     socket
     |> put_flash(:success, message)
     |> insert_saved_transaction(transaction, action)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> recalculate_summary()
     |> push_patch(to: ~p"/transactions")}
  end

  @impl true
  def handle_info({:transaction_duplicate}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Transação idêntica já existe — nada foi criado.")
     |> push_patch(to: ~p"/transactions")}
  end

  @impl true
  def handle_info(:do_auto_categorize, socket) do
    Transactions.reapply_auto_categorization()

    {:noreply,
     socket
     |> assign(:auto_categorizing, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> put_flash(:success, "Regras aplicadas!")
     |> refresh_transactions_page1(socket.assigns.filters)}
  end

  def handle_info(:reimbursement_linked, socket) do
    {:noreply,
     socket
     |> assign(:show_reimbursement_modal, false)
     |> put_flash(:success, "Reembolso vinculado e categorizado!")
     |> refresh_transactions_page1(socket.assigns.filters)}
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
     |> refresh_transactions_page1(socket.assigns.filters)}
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
      |> recalculate_summary()
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

  # Single-row convenience over CategorySuggester.annotate/1 and PluggyMatcher.annotate/2
  # so streamed rows never lose their suggestion pill or pluggy category badge.
  defp annotate_one(tx) do
    [tx] =
      [tx]
      |> CategorySuggester.annotate()
      |> annotate_pluggy_categories()

    tx
  end

  # A brand new row belongs at the top of the (newest first) statement; an
  # edited one goes through the filter-aware update path so it disappears when
  # the change moved it out of the current filter.
  defp insert_saved_transaction(socket, transaction, :new) do
    tx = annotate_one(Transactions.get_transaction!(transaction.id))

    if matches_filters?(tx, socket.assigns.filters, socket.assigns.transfer_category_id) do
      stream_insert(socket, :transactions, tx, at: 0)
    else
      socket
    end
  end

  defp insert_saved_transaction(socket, transaction, :edit) do
    stream_update_transaction(socket, transaction)
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

  defp live_preview_cache,
    do: Application.get_env(:cash_lens, :pluggy_live_preview_cache, LivePreviewCache)

  defp fetch_pluggy_credentials do
    client_id = System.get_env("PLUGGY_CLIENT_ID")
    client_secret = System.get_env("PLUGGY_CLIENT_SECRET")

    if is_binary(client_id) and is_binary(client_secret) and client_id != "" and
         client_secret != "" do
      {:ok, client_id, client_secret}
    else
      {:error, :missing_credentials}
    end
  end

  defp refresh_transactions_page1(socket, filters) do
    db_transactions =
      Transactions.list_transactions(map_filters(filters), 1)
      |> annotate_pluggy_categories()

    {live_entries, pluggy_error} = live_preview_entries(filters)

    socket
    |> assign(:page, 1)
    |> assign(:end_of_list?, length(db_transactions) < page_size())
    |> assign(:transfer_pairs, %{})
    |> assign(:reimbursement_pairs, %{})
    |> assign(:pluggy_error, pluggy_error)
    |> assign(:live_entries, live_entries)
    |> recalculate_summary()
    |> load_transfer_pairs(db_transactions)
    |> load_reimbursement_pairs(db_transactions)
    # `reset: true` is what keeps a filter change from appending to the
    # previous result set: page 1 replaces the stream wholesale.
    |> stream(:transactions, db_transactions, reset: true)
    |> insert_live_entries(live_entries)
  end

  defp annotate_pluggy_categories(transactions) do
    all_cached_entries = safe_cache(fn -> live_preview_cache().get_all_entries() end, [])
    PluggyMatcher.annotate(transactions, all_cached_entries)
  end

  # Recomputes the summary INCLUDING the live entries currently on screen.
  # Any handler that touches the totals without rebuilding the stream must use
  # this instead of `calculate_summary/1`, otherwise the displayed total drops
  # by the live entries' amount while their rows are still visible.
  defp recalculate_summary(socket) do
    socket
    |> calculate_summary()
    |> add_live_summary(socket.assigns.live_entries)
  end

  # Every live entry's date is newer than any already-persisted transaction
  # for its account (see `LivePreview.from_date/1`), so they belong ahead of
  # the real rows, not appended after them (`stream_insert/4`'s default).
  # Inserting oldest-to-newest, each `at: 0`, lands them at the top in
  # newest-first order, matching the real rows' own date-desc ordering.
  defp insert_live_entries(socket, entries) do
    entries
    |> Enum.sort_by(& &1.date, {:asc, Date})
    |> Enum.reduce(socket, fn entry, acc ->
      stream_insert(acc, :transactions, entry, at: 0)
    end)
  end

  defp add_live_summary(socket, []), do: socket

  defp add_live_summary(socket, live_entries) do
    live_income =
      live_entries
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))

    live_expenses =
      live_entries
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, Decimal.abs(&1.amount)))

    update(socket, :summary, fn summary ->
      %{
        income: Decimal.add(summary.income, live_income),
        expenses: Decimal.add(summary.expenses, live_expenses)
      }
    end)
  end

  # Filters a live entry cannot structurally satisfy (category, reimbursement
  # status, unmatched-transfers, amount — whose matching semantics live in the
  # DB query) or that navigate away from "now" (month/year — a live entry only
  # ever reflects the current period, so showing it under a past/future month
  # view would be actively wrong, not just unfiltered):
  # if any of these are active, live entries are excluded entirely rather
  # than guessed at. Returns `{live_entries, pluggy_error}` where
  # `pluggy_error` is `nil` on a healthy cache, or `{reason, last_success_at}`
  # when the last refresh failed.
  defp live_preview_entries(filters) do
    case safe_cache(fn -> live_preview_cache().get_status() end, :unavailable) do
      {:ok, _at} ->
        {matching_live_entries(filters), nil}

      {:error, reason, last_success_at} ->
        {[], banner_error(reason, last_success_at)}

      :unavailable ->
        {[], nil}
    end
  end

  # The cache is an optional, best-effort component (and is deliberately not
  # started at all in `:test`). If it isn't running, the Transactions page
  # must still render — showing only persisted rows, with no scary banner —
  # rather than crashing the LiveView.
  defp safe_cache(fun, default) do
    fun.()
  catch
    :exit, _reason -> default
  end

  # A red, non-dismissing banner is for "something broke", not for "there is
  # nothing to show yet". Suppress it when no account is even linked to
  # Pluggy, and when the only reason is un-configured credentials or a
  # first refresh that hasn't landed yet with no prior success to lose.
  defp banner_error(reason, last_success_at) do
    cond do
      CashLens.Pluggy.list_linked_account_links() == [] -> nil
      last_success_at == nil and reason in [:missing_credentials, :not_yet_fetched] -> nil
      true -> {reason, last_success_at}
    end
  end

  # User-facing Portuguese text for every reason the banner can actually
  # reach — never a raw `inspect/1` of an Elixir term.
  defp pluggy_error_message(:missing_credentials),
    do: "credenciais do Pluggy não configuradas"

  defp pluggy_error_message(:not_yet_fetched),
    do: "ainda não houve uma primeira atualização"

  defp pluggy_error_message({:exception, message}),
    do: "erro inesperado (#{message})"

  defp pluggy_error_message({:exit, _reason}),
    do: "a atualização foi interrompida antes de terminar"

  defp pluggy_error_message(_reason),
    do: "falha ao comunicar com o Pluggy"

  defp matching_live_entries(filters) do
    if incompatible_filters_active?(filters) do
      []
    else
      filters
      |> live_entries_for_account_filter()
      |> LivePreview.filter_temporary_entries()
      |> Enum.filter(&matches_live_entry_filters?(&1, filters))
    end
  end

  defp live_entries_for_account_filter(%{"account_id" => account_id})
       when account_id not in [nil, ""] do
    safe_cache(fn -> live_preview_cache().get_entries(account_id) end, [])
  end

  defp live_entries_for_account_filter(_filters),
    do: safe_cache(fn -> live_preview_cache().get_all_entries() end, [])

  @live_entry_incompatible_filters ~w(category_id reimbursement_status month year amount)

  defp incompatible_filters_active?(filters) do
    filters["unmatched_transfers"] == "true" or
      Enum.any?(@live_entry_incompatible_filters, &((filters[&1] || "") != ""))
  end

  defp matches_live_entry_filters?(entry, filters) do
    matches_live_search?(entry, filters["search"]) and
      matches_live_date?(entry, filters["date"]) and
      matches_live_date_range?(entry, filters["date_from"], filters["date_to"]) and
      matches_live_type?(entry, filters["type"])
  end

  defp matches_live_search?(_entry, search) when search in [nil, ""], do: true

  defp matches_live_search?(entry, search) do
    String.contains?(String.downcase(entry.description), String.downcase(search))
  end

  defp matches_live_date?(_entry, date) when date in [nil, ""], do: true

  defp matches_live_date?(entry, date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.compare(entry.date, parsed) == :eq
      _ -> true
    end
  end

  defp matches_live_date_range?(_entry, from, _to) when from in [nil, ""], do: true
  defp matches_live_date_range?(_entry, _from, to) when to in [nil, ""], do: true

  defp matches_live_date_range?(entry, from, to) do
    with {:ok, date_from} <- Date.from_iso8601(from),
         {:ok, date_to} <- Date.from_iso8601(to) do
      Date.compare(entry.date, date_from) != :lt and Date.compare(entry.date, date_to) != :gt
    else
      _ -> true
    end
  end

  defp matches_live_type?(_entry, type) when type not in ["debit", "expense", "credit", "income"],
    do: true

  defp matches_live_type?(entry, type) when type in ["debit", "expense"],
    do: Decimal.negative?(entry.amount)

  defp matches_live_type?(entry, type) when type in ["credit", "income"],
    do: Decimal.positive?(entry.amount)

  defp calculate_summary(socket) do
    mapped = map_filters(socket.assigns.filters)
    active? = filters_active?(socket.assigns.filters)

    # The count only ever backs the filtered-summary card, so it is not worth
    # a COUNT(*) over the whole table while the health bar is the one showing.
    filtered_count = if active?, do: Transactions.count_transactions(mapped), else: nil

    summary = Transactions.get_filtered_summary(mapped)

    socket
    |> assign(:statement_health, Transactions.statement_health())
    |> assign(:filtered_count, filtered_count)
    |> assign(:filters_active?, active?)
    |> assign(:summary, summary)
  end

  defp load_reimbursement_pairs(socket, transactions) do
    keys =
      transactions
      |> Enum.map(&Map.get(&1, :reimbursement_link_key))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    new_pairs = Transactions.get_reimbursement_pairs(keys)

    assign(
      socket,
      :reimbursement_pairs,
      Map.merge(socket.assigns.reimbursement_pairs, new_pairs)
    )
  end

  # The counterpart of `tx` in its reimbursement pair — the deposit credit when
  # `tx` is the expense, the expense when `tx` is the credit. `nil` when the
  # row is unlinked or the other side isn't loaded.
  defp reimbursement_counterpart(pairs, tx) do
    case Map.get(pairs, Map.get(tx, :reimbursement_link_key)) do
      nil -> nil
      group -> Enum.find(group, &(&1.id != tx.id))
    end
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

  # The period select is a friendly face over the month/year filters: picking
  # "Todos os Períodos" (the default) clears both, so the statement opens as a
  # continuous flow instead of locked to the current month.
  defp normalize_period(filters, %{"period" => period}) do
    case String.split(period || "", "-") do
      [year, month] when byte_size(year) == 4 and byte_size(month) == 2 ->
        filters |> Map.put("year", year) |> Map.put("month", month)

      _ ->
        filters |> Map.put("period", "") |> Map.put("year", "") |> Map.put("month", "")
    end
  end

  defp normalize_period(filters, _params), do: filters

  # Keeps the select in sync when month/year are changed by something other
  # than the select itself (month arrows, "Pendentes", "Limpar filtros").
  defp sync_period(filters) do
    case {filters["year"], filters["month"]} do
      {year, month} when year in [nil, ""] or month in [nil, ""] ->
        Map.put(filters, "period", "")

      {year, month} ->
        Map.put(filters, "period", "#{year}-#{String.pad_leading(month, 2, "0")}")
    end
  end

  # Last 12 months, newest first, as `{label, value}` pairs for the select.
  # A period arriving from outside that window (a deep link from the month
  # closing screen, say) is prepended so the select still shows what is
  # actually being filtered instead of silently falling back.
  defp period_options(current) do
    today = Date.utc_today()

    options =
      Enum.map(0..11, fn offset ->
        date = shift_months(today, -offset)
        {"#{month_name(date.month)} #{date.year}", "#{date.year}-#{pad2(date.month)}"}
      end)

    cond do
      current in [nil, ""] -> options
      Enum.any?(options, fn {_label, value} -> value == current end) -> options
      true -> [{period_label(current), current} | options]
    end
  end

  defp period_label(period) do
    case String.split(period, "-") do
      [year, month] -> "#{month_name(String.to_integer(month))} #{year}"
      _ -> period
    end
  end

  defp shift_months(date, offset) do
    total = date.year * 12 + (date.month - 1) + offset
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  defp pad2(month), do: month |> Integer.to_string() |> String.pad_leading(2, "0")

  defp page_size, do: Transactions.default_page_size()

  defp default_filters do
    %{
      "search" => "",
      "period" => "",
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
