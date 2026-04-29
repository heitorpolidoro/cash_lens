defmodule CashLensWeb.TransactionLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Transactions

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CashLens.PubSub, "categories")
    accounts = Accounts.list_accounts()

    {:ok,
     socket
     |> assign(:page_title, "Transactions")
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
     |> assign(:unmatched_transfers_count, 0)}
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
       |> put_flash(:info, "Reimbursement link removed.")
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
        {:noreply, put_flash(socket, :error, "Update failed")}
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
     |> put_flash(:info, "Bulk categorized!")
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
     |> put_flash(:info, "Rules applied!")
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
        # Find or create "Income" category
        category =
          case Categories.get_category_by_slug("income") do
            nil ->
              {:ok, cat} =
                Categories.create_category(%{
                  name: "Income",
                  slug: "income",
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
          description: "Balance Adjustment (Income)"
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
     |> put_flash(:info, "Balance adjusted successfully!")
     |> calculate_summary()
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info(:reimbursement_linked, socket) do
    {:noreply,
     socket
     |> assign(:show_reimbursement_modal, false)
     |> put_flash(:info, "Reimbursement linked and categorized!")
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
     |> put_flash(:info, message)
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info({:category_created, category, target_transaction_id}, socket) do
    if target_transaction_id do
      Transactions.update_transaction_category(
        target_transaction_id,
        category.id
      )

      tx = Transactions.get_transaction!(target_transaction_id)

      socket =
        socket
        |> assign(:show_quick_category_modal, false)
        |> assign(:categories, Categories.list_categories())
        |> assign(:pending_count, Transactions.count_pending_transactions())
        |> put_flash(:info, "Category created!")

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

      socket =
        if matches_filters?(tx, socket.assigns.filters),
          do: stream_insert(socket, :transactions, tx),
          else: stream_delete(socket, :transactions, tx)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :categories, Categories.list_categories())}
    end
  end

  @impl true
  def handle_info(:close_import_modal, socket) do
    {:noreply, assign(socket, :show_import_modal, false)}
  end

  @impl true
  def handle_info({:import_success, count}, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> put_flash(:info, "Success! #{count} transactions imported.")
     |> stream(
       :transactions,
       Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
       reset: true
     )}
  end

  @impl true
  def handle_info({:import_error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Import error: #{reason}")}
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
    month
  end
end
