defmodule CashLensWeb.InstallmentLive.Index do
  @moduledoc """
  Consolidated view of every long-term commitment: credit-card instalment
  purchases, financings and consórcios.

  The screen is read-only over the domain: all aggregation (monthly commitment,
  consolidated outstanding balance, next-month cash-flow relief and the stacked
  monthly projection) lives in `CashLens.Installments`. The heavy statement-wide
  installment scan is deliberately NOT offered here — it runs automatically in
  the import pipeline and can be triggered manually from `/admin/db`.
  """
  use CashLensWeb, :live_view

  alias CashLens.Installments
  alias CashLens.Installments.InstallmentGroup

  @projection_months 10
  @relief_preview 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:show_modal, false)
     |> assign(:show_relief, false)
     |> assign(:expanded_ids, MapSet.new())
     |> assign(:commitment, %InstallmentGroup{})
     |> assign(:commitment_params, %{})
     |> assign(:suggestions, [])
     |> assign(:suggestion_query, "")
     |> assign(:applied_suggestion, nil)
     |> assign(:delete_candidate, nil)
     |> assign(:commitment_types, Installments.commitment_types())
     |> assign(:relief_preview, @relief_preview)
     |> assign_form()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:type_filter, filter_value(params["type"], known_types(), "all"))
     |> assign(:status_filter, filter_value(params["status"], ~w(active completed all), "active"))
     |> assign(:query, params["q"] || "")
     |> load_data()}
  end

  defp known_types, do: ["all" | Installments.commitment_types()]

  defp filter_value(value, allowed, default) do
    if value in allowed, do: value, else: default
  end

  defp load_data(socket) do
    reference = Installments.current_month()
    groups = Enum.map(Installments.list_installment_groups(), &decorate/1)

    socket
    |> assign(:commitments, filter_commitments(groups, socket.assigns))
    |> assign(:counts, active_counts(groups))
    |> assign(:active_count, Enum.count(groups, &(not &1.is_finished)))
    |> assign(:month_metrics, Installments.monthly_commitment(reference))
    |> assign(:balance, Installments.outstanding_balance(reference))
    |> assign(:relief, Installments.cash_flow_relief(reference))
    |> assign(:projection, Installments.monthly_projection(reference, @projection_months))
    |> assign(:reference_month, reference)
  end

  defp decorate(group) do
    group.id
    |> Installments.get_group_with_progress()
    |> then(fn g ->
      g
      |> Map.put(:last_installment_date, Installments.last_installment_date(g))
      |> Map.put(:commitment_type, Installments.commitment_type(g))
      |> Map.put(:outstanding, Installments.remaining_debt(g))
      |> Map.put(:elapsed_count, g.installments - Installments.remaining_parcels(g))
    end)
  end

  defp filter_commitments(groups, assigns) do
    groups
    |> Enum.filter(fn group ->
      type_match?(group, assigns.type_filter) and
        status_match?(group, assigns.status_filter) and
        query_match?(group, assigns.query)
    end)
    |> Enum.sort_by(&sort_key/1)
    |> zebra_by_payoff()
  end

  # The table is sorted by payoff month, so consecutive rows that share one
  # share a band. The flag flips on every month change, not on every row, which
  # is what makes a run of plans ending together read as one block.
  defp zebra_by_payoff(groups) do
    {tagged, _, _} =
      Enum.reduce(groups, {[], nil, false}, fn group, {acc, previous, shaded?} ->
        key = sort_key(group)
        shaded? = if is_nil(previous) or key == previous, do: shaded?, else: not shaded?
        {[Map.put(group, :zebra?, shaded?) | acc], key, shaded?}
      end)

    Enum.reverse(tagged)
  end

  defp type_match?(_group, "all"), do: true
  defp type_match?(group, type), do: group.commitment_type == type

  defp status_match?(_group, "all"), do: true
  defp status_match?(group, "completed"), do: group.is_finished
  defp status_match?(group, _active), do: not group.is_finished

  defp query_match?(_group, blank) when blank in [nil, ""], do: true

  defp query_match?(group, needle) do
    needle = String.downcase(needle)

    [group.description_pattern, group.institution]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  defp sort_key(group) do
    case group.last_installment_date do
      %Date{} = date -> {date.year, date.month}
      # coveralls-ignore-next-line — defensive: start_date is required in practice.
      _ -> {9999, 12}
    end
  end

  defp active_counts(groups) do
    active = Enum.reject(groups, & &1.is_finished)

    Map.new(Installments.commitment_types(), fn type ->
      {type, Enum.count(active, &(&1.commitment_type == type))}
    end)
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:commitment, %InstallmentGroup{})
     |> assign(:commitment_params, %{"commitment_type" => "credit_card"})
     |> reset_suggestions()
     |> assign_form()}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    group = Installments.get_installment_group!(id)

    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:commitment, group)
     |> assign(:commitment_params, edit_params(group))
     |> reset_suggestions()
     |> assign_form()}
  end

  @impl true
  def handle_event("validate", %{"installment_group" => params}, socket) do
    params = maybe_derive_start_date(params, socket.assigns)
    {:noreply, socket |> assign(:commitment_params, params) |> assign_form()}
  end

  @impl true
  def handle_event("select_commitment_type", %{"type" => type}, socket) do
    params = Map.put(socket.assigns.commitment_params, "commitment_type", type)
    {:noreply, socket |> assign(:commitment_params, params) |> assign_form()}
  end

  @impl true
  def handle_event("search_suggestions", %{"suggestion" => %{"q" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:suggestion_query, query)
     |> assign(:suggestions, Installments.suggest_commitment_patterns(query))}
  end

  @impl true
  def handle_event("apply_suggestion", %{"description" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("apply_suggestion", %{"description" => description}, socket) do
    case Enum.find(socket.assigns.suggestions, &(&1.description == description)) do
      nil ->
        {:noreply, socket}

      suggestion ->
        # The term is deliberately NOT filled: the statement shows how many
        # parcels were paid, never how many the contract has left.
        params =
          socket.assigns.commitment_params
          |> Map.put("description_pattern", suggestion.description)
          |> Map.put("installment_amount", Decimal.to_string(suggestion.amount, :normal))
          |> put_start_date(suggestion)

        {:noreply,
         socket
         |> assign(:commitment_params, params)
         |> assign(:applied_suggestion, suggestion)
         |> assign_form()}
    end
  end

  @impl true
  def handle_event("clear_suggestion", _params, socket) do
    {:noreply, reset_suggestions(socket)}
  end

  @impl true
  def handle_event("save", %{"installment_group" => params}, socket) do
    save_commitment(socket, socket.assigns.commitment, params)
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => query}}, socket) do
    {:noreply, push_patch(socket, to: filter_path(socket.assigns, q: query))}
  end

  @impl true
  def handle_event("ask_delete", %{"id" => id}, socket) do
    group = Enum.find(socket.assigns.commitments, &(&1.id == id))
    {:noreply, assign(socket, :delete_candidate, group)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_candidate, nil)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    group = Installments.get_installment_group!(id)
    {:ok, _} = Installments.delete_installment_group(group)
    {:noreply, socket |> assign(:delete_candidate, nil) |> load_data()}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_ids, id),
        do: MapSet.delete(socket.assigns.expanded_ids, id),
        else: MapSet.put(socket.assigns.expanded_ids, id)

    {:noreply, assign(socket, :expanded_ids, expanded)}
  end

  @impl true
  def handle_event("show_relief", _params, socket) do
    {:noreply, assign(socket, :show_relief, true)}
  end

  @impl true
  def handle_event("close_relief", _params, socket) do
    {:noreply, assign(socket, :show_relief, false)}
  end

  defp save_commitment(socket, %InstallmentGroup{id: nil}, params) do
    case Installments.create_installment_group(params) do
      {:ok, _group} -> {:noreply, close_and_reload(socket, "Compromisso criado com sucesso!")}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_commitment(socket, group, params) do
    case Installments.update_installment_group(group, params) do
      {:ok, _group} -> {:noreply, close_and_reload(socket, "Compromisso atualizado!")}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp close_and_reload(socket, message) do
    socket
    |> assign(:show_modal, false)
    |> load_data()
    |> put_flash(:success, message)
  end

  defp assign_form(socket) do
    changeset =
      Installments.change_installment_group(
        socket.assigns.commitment,
        socket.assigns.commitment_params
      )

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:modal_type, Ecto.Changeset.get_field(changeset, :commitment_type) || "credit_card")
  end

  defp filter_path(assigns, overrides) do
    params =
      %{
        "type" => assigns.type_filter,
        "status" => assigns.status_filter,
        "q" => assigns.query
      }
      |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/installments?#{params}"
  end

  # ── View helpers ──────────────────────────────────────────────────────────

  defp type_label("financing"), do: "Financiamento"
  defp type_label("consorcio"), do: "Consórcio"
  defp type_label(_credit_card), do: "Cartão"

  defp type_icon("financing"), do: "🏠"
  defp type_icon("consorcio"), do: "🤝"
  defp type_icon(_credit_card), do: "💳"

  defp type_tab_label("all"), do: "🌐 Todos"
  defp type_tab_label("financing"), do: "🏠 Financiamentos"
  defp type_tab_label("consorcio"), do: "🤝 Consórcios"
  defp type_tab_label(_credit_card), do: "💳 Cartão de Crédito"

  defp breakdown_caption(type, count) do
    "#{breakdown_label(type)} (#{count} #{unit_label(type, count)})"
  end

  defp relief_type_label("financing"), do: "Financiamento"
  defp relief_type_label("consorcio"), do: "Consórcio"
  defp relief_type_label(_credit_card), do: "Parcelamento no cartão"

  defp breakdown_label("financing"), do: "Financiamentos"
  defp breakdown_label("consorcio"), do: "Consórcios"
  defp breakdown_label(_credit_card), do: "Parcelamentos Cartão"

  defp unit_label("financing", 1), do: "contrato"
  defp unit_label("financing", _n), do: "contratos"
  defp unit_label("consorcio", 1), do: "cota"
  defp unit_label("consorcio", _n), do: "cotas"
  defp unit_label(_credit_card, 1), do: "compra"
  defp unit_label(_credit_card, _n), do: "compras"

  defp tab_count(_counts, active_count, "all"), do: active_count
  defp tab_count(counts, _active_count, type), do: Map.get(counts, type, 0)

  defp projected_amount(month, "financing"), do: month.financing
  defp projected_amount(month, "consorcio"), do: month.consorcio
  defp projected_amount(month, _credit_card), do: month.credit_card

  defp dot_class("financing"), do: "bg-indigo-500"
  defp dot_class("consorcio"), do: "bg-amber-500"
  defp dot_class(_credit_card), do: "bg-blue-500"

  defp badge_class("financing"), do: "bg-indigo-500/10 text-indigo-600 border-indigo-500/30"
  defp badge_class("consorcio"), do: "bg-amber-500/10 text-amber-600 border-amber-500/30"
  defp badge_class(_credit_card), do: "bg-blue-500/10 text-blue-600 border-blue-500/30"

  defp progress_class("financing"), do: "bg-indigo-500"
  defp progress_class("consorcio"), do: "bg-amber-500"
  defp progress_class(_credit_card), do: "bg-blue-500"

  # Percentage of each commitment type within a projected month, in the stacking
  # order used by the ribbon (financing at the base, card on top). The three
  # shares always describe the same total the cell displays.
  defp stack_shares(month) do
    [
      {"financing", share(month.financing, month.total)},
      {"consorcio", share(month.consorcio, month.total)},
      {"credit_card", share(month.credit_card, month.total)}
    ]
  end

  defp share(amount, total) do
    if Decimal.eq?(total, 0) do
      0.0
    else
      amount |> Decimal.div(total) |> Decimal.mult(100) |> Decimal.to_float() |> Float.round(2)
    end
  end

  defp month_chip(%Date{} = date) do
    yy = date.year |> Integer.to_string() |> String.slice(-2, 2)
    "#{month_label(date.month)}/#{yy}"
  end

  defp last_parcel_label(group) do
    case group.last_installment_date do
      %Date{} = date -> String.downcase(month_chip(date))
      # coveralls-ignore-next-line — defensive: start_date is required in practice.
      _ -> "---"
    end
  end

  defp progress_count(%{commitment_type: "credit_card"} = group), do: group.paid_count
  defp progress_count(group), do: group.elapsed_count

  defp progress_pct(group) do
    count = progress_count(group)

    if group.installments > 0,
      do: round(count / group.installments * 100),
      # coveralls-ignore-next-line — defensive: installments is validated > 1.
      else: 0
  end

  defp parcel_status(%{date: %Date{} = date}) do
    if Date.compare(date, Date.utc_today()) == :gt, do: "a vencer", else: "paga"
  end

  # coveralls-ignore-next-line — defensive: a transaction always carries a date.
  defp parcel_status(_parcel), do: "—"

  # "Parcelas já pagas" is not stored, so an edit would open with it blank and the
  # operator could not tell 81 of 360 from 1 of 360 without doing the arithmetic.
  # It is derived back from the dates the group does store.
  defp edit_params(group) do
    paid =
      group.installments - Installments.remaining_parcels(group, Installments.current_month())

    %{
      "commitment_type" => Installments.commitment_type(group),
      "paid_installments" => to_string(paid)
    }
  end

  # "Parcelas já pagas" is the only way to reach a contract that began before the
  # imported history: 81 paid parcels put the first one 80 months before the last
  # one billed. It rewrites `start_date` only on the event that changes it, so a
  # date typed by hand afterwards survives.
  defp maybe_derive_start_date(params, assigns) do
    previous = Map.get(assigns.commitment_params, "paid_installments")
    typed = Map.get(params, "paid_installments")

    with true <- typed not in [nil, ""] and typed != previous,
         paid when is_integer(paid) <- paid_count(params),
         %Date{} = anchor <- paid_anchor(assigns) do
      first = Installments.add_months(anchor, -(paid - 1))
      Map.put(params, "start_date", Date.to_iso8601(first))
    else
      _ -> params
    end
  end

  # Picking a pattern normally dates the plan from its first occurrence — but a
  # paid count already on the form outranks it, re-anchored on the pattern just
  # picked. Otherwise the date would silently contradict the number still shown
  # in "parcelas já pagas".
  defp put_start_date(params, suggestion) do
    date =
      case paid_count(params) do
        nil -> suggestion.first_date
        paid -> Installments.add_months(suggestion.last_date, -(paid - 1))
      end

    Map.put(params, "start_date", Date.to_iso8601(date))
  end

  defp paid_count(params) do
    case params |> Map.get("paid_installments") |> to_string() |> Integer.parse() do
      {paid, ""} when paid > 0 -> paid
      _ -> nil
    end
  end

  # The newest parcel already billed: the statement's last occurrence when one
  # was picked from the history, otherwise last month.
  defp paid_anchor(%{applied_suggestion: %{last_date: %Date{} = date}}), do: date
  defp paid_anchor(_assigns), do: Installments.add_months(Date.utc_today(), -1)

  # What the typed term and start date add up to, so the contract can be checked
  # against the form before saving.
  defp term_summary(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = changeset}) do
    changeset |> Ecto.Changeset.apply_changes() |> term_summary()
  end

  defp term_summary(%{start_date: %Date{} = start_date, installments: n})
       when is_integer(n) and n > 0 do
    group = %{start_date: start_date, installments: n}
    remaining = Installments.remaining_parcels(group, Installments.current_month())

    %{
      paid: n - remaining,
      remaining: remaining,
      ends_on: Installments.last_installment_date(group)
    }
  end

  defp term_summary(_form_data), do: nil

  # Spells out what survives: the parcels are unlinked, never deleted, and the
  # count is the one number that tells the operator how much is at stake.
  defp delete_confirm(%{paid_count: 0} = group) do
    "Excluir \"#{group.description_pattern}\"? Nenhum lançamento está vinculado a ele."
  end

  defp delete_confirm(%{paid_count: 1} = group) do
    "Excluir \"#{group.description_pattern}\"? O lançamento vinculado volta a ser " <>
      "uma transação solta — não é apagado."
  end

  defp delete_confirm(%{paid_count: count} = group) do
    "Excluir \"#{group.description_pattern}\"? Os #{count} lançamentos vinculados voltam " <>
      "a ser transações soltas — nenhum é apagado."
  end

  defp reset_suggestions(socket) do
    socket
    |> assign(:suggestion_query, "")
    |> assign(:suggestions, Installments.suggest_commitment_patterns())
    |> assign(:applied_suggestion, nil)
  end

  defp suggestion_period(%{first_date: %Date{} = from, last_date: %Date{} = to}) do
    "#{month_chip(from)} → #{month_chip(to)}"
  end
end
