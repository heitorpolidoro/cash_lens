defmodule CashLensWeb.MonthLive.Show do
  @moduledoc """
  Month closing screen: one month in detail, or two months compared.

  The route (`/months/:year/:month`) always carries the month under analysis.
  Adding `?compare_year=&compare_month=` turns on the comparison and names the
  base (older) month. The pair is kept strictly chronological — base before
  analysis — both when the params arrive and when the navigation controls are
  used, so the "Diferença" column always reads *analysis − base*.
  """
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Transactions
  alias CashLensWeb.MonthLive.MonthPanel

  @years_back 6
  @years_ahead 1
  # `list_balances/3` is paginated; one month never has more rows than the number
  # of accounts, so a single generous page covers it.
  @balances_page_size 500

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"year" => year, "month" => month} = params, _uri, socket) do
    case parse_period(year, month) do
      {:ok, analysis} ->
        {:noreply, apply_period(socket, analysis, base_period(params, analysis))}

      :error ->
        today = Date.utc_today()
        {:noreply, push_navigate(socket, to: ~p"/months/#{today.year}/#{today.month}")}
    end
  end

  @impl true
  def handle_event("toggle_compare", _params, socket) do
    analysis = current_analysis(socket)

    to =
      if socket.assigns.comparison,
        do: period_path(analysis, nil),
        else: period_path(analysis, previous_month(analysis))

    {:noreply, push_patch(socket, to: to)}
  end

  @impl true
  def handle_event("nav", %{"scope" => scope, "unit" => unit, "dir" => dir}, socket) do
    {:noreply, move(socket, scope, fn period -> shift(period, unit, String.to_integer(dir)) end)}
  end

  @impl true
  def handle_event("select_period", %{"scope" => scope, "year" => year}, socket) do
    {:noreply, move(socket, scope, fn {_y, m} -> {String.to_integer(year), m} end)}
  end

  @impl true
  def handle_event("select_period", %{"scope" => scope, "month" => month}, socket) do
    {:noreply, move(socket, scope, fn {y, _m} -> {y, String.to_integer(month)} end)}
  end

  @impl true
  def handle_event("toggle_category", %{"category_id" => row_key}, socket) do
    single = socket.assigns.single

    if MapSet.member?(single.expanded, row_key) do
      {:noreply,
       assign(socket, :single, %{single | expanded: MapSet.delete(single.expanded, row_key)})}
    else
      transactions =
        Map.get_lazy(single.transactions, row_key, fn ->
          load_row_transactions(single, row_key)
        end)

      {:noreply,
       assign(socket, :single, %{
         single
         | expanded: MapSet.put(single.expanded, row_key),
           transactions: Map.put(single.transactions, row_key, transactions)
       })}
    end
  end

  # row_key is namespaced as "<type>:<category_id>" so the income and expense
  # sections never collide (e.g. both have an "Uncategorized" row) and each
  # expansion only loads transactions of the matching sign.
  defp load_row_transactions(single, row_key) do
    [type, category_id] = String.split(row_key, ":", parts: 2)

    Transactions.list_all_transactions(%{
      "category_id" => category_id,
      "type" => type,
      "month" => to_string(single.month),
      "year" => to_string(single.year),
      "sort_order" => "asc"
    })
  end

  # Applies a move to one of the periods on screen, refusing the ones that would
  # break the comparison's chronological order.
  defp move(socket, "single", fun) do
    push_patch(socket, to: socket.assigns.single |> period_of() |> fun.() |> period_path(nil))
  end

  defp move(socket, side, fun) do
    %{base: base, analysis: analysis} = socket.assigns.comparison

    {new_base, new_analysis} =
      case side do
        "base" -> {fun.(period_of(base)), period_of(analysis)}
        "analysis" -> {period_of(base), fun.(period_of(analysis))}
      end

    if before?(new_base, new_analysis) do
      push_patch(socket, to: period_path(new_analysis, new_base))
    else
      socket
    end
  end

  defp apply_period(socket, analysis, nil) do
    socket
    |> assign(:year_options, year_options([analysis]))
    |> assign(:comparison, nil)
    |> assign(:single, build_single(analysis))
  end

  defp apply_period(socket, analysis, base) do
    socket
    |> assign(:year_options, year_options([analysis, base]))
    |> assign(:single, nil)
    |> assign(:comparison, build_comparison(base, analysis))
  end

  defp build_single({year, month}) do
    {opening, final} = consolidated_balances(year, month)
    income_rows = Transactions.get_month_income_breakdown(year, month)
    expense_rows = Transactions.get_month_category_breakdown(year, month)
    income_total = total_of(income_rows)
    expense_total = total_of(expense_rows)

    %{
      year: year,
      month: month,
      opening_balance: opening,
      final_balance: final,
      income_total: income_total,
      expense_total: expense_total,
      net: Decimal.sub(income_total, expense_total),
      income_rows: with_pct(income_rows, income_total),
      expense_rows: with_pct(expense_rows, expense_total),
      expanded: MapSet.new(),
      transactions: %{}
    }
  end

  defp build_comparison(base, analysis) do
    base_totals = month_totals(base)
    analysis_totals = month_totals(analysis)

    %{
      base: base_totals,
      analysis: analysis_totals,
      income_rows:
        union_rows(
          base_totals.income_breakdown,
          analysis_totals.income_breakdown,
          base_totals.income_total,
          analysis_totals.income_total
        ),
      expense_rows:
        union_rows(
          base_totals.expense_breakdown,
          analysis_totals.expense_breakdown,
          base_totals.expense_total,
          analysis_totals.expense_total
        ),
      income_delta: Decimal.sub(analysis_totals.income_total, base_totals.income_total),
      expense_delta: Decimal.sub(analysis_totals.expense_total, base_totals.expense_total),
      net_delta: Decimal.sub(analysis_totals.net, base_totals.net),
      blocked: blocked_moves(base, analysis)
    }
  end

  defp month_totals({year, month}) do
    income_breakdown = Transactions.get_month_income_breakdown(year, month)
    expense_breakdown = Transactions.get_month_category_breakdown(year, month)
    income_total = total_of(income_breakdown)
    expense_total = total_of(expense_breakdown)

    %{
      year: year,
      month: month,
      income_total: income_total,
      expense_total: expense_total,
      net: Decimal.sub(income_total, expense_total),
      income_breakdown: income_breakdown,
      expense_breakdown: expense_breakdown
    }
  end

  # The active union of both months: every category that moved in at least one of
  # them. A category that moved in only one side still gets a row on the other,
  # showing R$ 0,00 and the delta; a category that moved in neither is absent
  # altogether (breakdown queries only return non-zero categories).
  #
  # The analysed month's own ranking drives the shared order, with the
  # base-only categories appended in the base month's ranking, so both panels
  # print the same rows on the same lines.
  defp union_rows(base_rows, analysis_rows, base_total, analysis_total) do
    base_by_id = Map.new(base_rows, &{&1.category_id, &1})
    analysis_by_id = Map.new(analysis_rows, &{&1.category_id, &1})

    base_only = Enum.reject(base_rows, &Map.has_key?(analysis_by_id, &1.category_id))

    Enum.map(analysis_rows ++ base_only, fn row ->
      base_value = row_total(base_by_id[row.category_id])
      analysis_value = row_total(analysis_by_id[row.category_id])

      %{
        category_id: row.category_id,
        name: row.name,
        type: row.type,
        base_total: base_value,
        analysis_total: analysis_value,
        base_pct: percentage(base_value, base_total),
        analysis_pct: percentage(analysis_value, analysis_total),
        delta: Decimal.sub(analysis_value, base_value)
      }
    end)
  end

  # This screen reports one transaction universe and one only: the operational
  # month as the category breakdowns see it — every account, credit cards
  # included, minus transfers and card payments (which are settlement, not
  # spending, and would double-count the purchases they pay for).
  #
  # So both `Receitas`/`Despesas` totals are summed straight from the rows of
  # `get_month_income_breakdown/2` and `get_month_category_breakdown/2` rather
  # than read from `Transactions.get_monthly_summary/1`, whose `account_id`
  # filter restricts it to `is_credit_card == false` and therefore answers a
  # different question. Deriving the total from the same rows the table prints
  # is what keeps `% do total` a true share: the denominator is by construction
  # the sum of the numerators, so the rows always add up to the KPI card above
  # them and no percentage can exceed 100%.
  #
  # `opening_balance`/`final_balance` are deliberately NOT part of this universe
  # — see `consolidated_balances/2`, they are a cash position, not a flow.
  defp total_of(rows), do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.total))

  defp row_total(nil), do: Decimal.new(0)
  defp row_total(row), do: row.total

  defp with_pct(rows, total) do
    Enum.map(rows, &Map.put(&1, :pct, percentage(&1.total, total)))
  end

  defp percentage(value, total) do
    if Decimal.gt?(total, 0),
      do: value |> Decimal.div(total) |> Decimal.mult(100) |> Decimal.round(1),
      else: Decimal.new("0.0")
  end

  # Consolidated opening/closing cash position of the month. Credit-card accounts
  # are left out: their balance is a debt, not cash on hand.
  defp consolidated_balances(year, month) do
    %{"year" => year, "month" => month}
    |> Accounting.list_balances(1, @balances_page_size)
    |> Enum.reject(&(&1.account && &1.account.is_credit_card))
    |> Enum.reduce({Decimal.new(0), Decimal.new(0)}, fn balance, {opening, final} ->
      {Decimal.add(opening, balance.initial_balance || Decimal.new(0)),
       Decimal.add(final, balance.final_balance || Decimal.new(0))}
    end)
  end

  # Which arrows would break the chronological order and must render disabled.
  defp blocked_moves(base, analysis) do
    %{
      "base" => blocked_side(base, fn candidate -> before?(candidate, analysis) end),
      "analysis" => blocked_side(analysis, fn candidate -> before?(base, candidate) end)
    }
  end

  defp blocked_side(period, allowed?) do
    Map.new(
      [
        prev_year: {"year", -1},
        next_year: {"year", 1},
        prev_month: {"month", -1},
        next_month: {"month", 1}
      ],
      fn {key, {unit, dir}} -> {key, not allowed?.(shift(period, unit, dir))} end
    )
  end

  defp period_of(%{year: year, month: month}), do: {year, month}

  defp current_analysis(socket) do
    case socket.assigns do
      %{comparison: %{analysis: analysis}} -> period_of(analysis)
      %{single: single} -> period_of(single)
    end
  end

  defp before?({base_year, base_month}, {year, month}),
    do: {base_year, base_month} < {year, month}

  defp shift({year, month}, "year", dir), do: {year + dir, month}

  defp shift({year, month}, "month", dir) do
    case month + dir do
      0 -> {year - 1, 12}
      13 -> {year + 1, 1}
      shifted -> {year, shifted}
    end
  end

  defp previous_month(period), do: shift(period, "month", -1)

  defp period_path({year, month}, nil), do: ~p"/months/#{year}/#{month}"

  defp period_path({year, month}, {base_year, base_month}),
    do: ~p"/months/#{year}/#{month}?compare_year=#{base_year}&compare_month=#{base_month}"

  defp parse_period(year, month) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      {:ok, {year, month}}
    else
      _ -> :error
    end
  end

  # A malformed compare pair degrades to "no comparison"; a valid but
  # non-chronological one is corrected to the month right before the analysed
  # one rather than flipping the panels under the user.
  defp base_period(params, analysis) do
    with year when is_binary(year) <- params["compare_year"],
         month when is_binary(month) <- params["compare_month"],
         {:ok, base} <- parse_period(year, month) do
      if before?(base, analysis), do: base, else: previous_month(analysis)
    else
      _ -> nil
    end
  end

  defp year_options(periods) do
    current = Date.utc_today().year
    viewed = Enum.map(periods, fn {year, _month} -> year end)

    (current - @years_back)..(current + @years_ahead)
    |> Enum.to_list()
    |> Kernel.++(viewed)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-8 space-y-6">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-2 border-b border-slate-200">
        <div>
          <h1 class="text-2xl font-bold text-slate-900 tracking-tight">Fechamento do Mês</h1>
          <p class="text-xs text-slate-500 mt-0.5">
            Demonstrativo de receitas e gastos por categoria
          </p>
        </div>

        <button
          type="button"
          id="toggle-compare"
          phx-click="toggle_compare"
          class={[
            "border font-bold px-3.5 py-2 rounded-xl text-xs transition flex items-center gap-2 shadow-sm",
            (@comparison && "bg-blue-50 text-blue-700 border-blue-200") ||
              "bg-white hover:bg-slate-50 text-slate-700 border-slate-200"
          ]}
        >
          <.icon name="hero-arrows-right-left" class="size-4 text-blue-600" />
          {if @comparison, do: "Fechar Comparação", else: "Ativar Comparação de Meses"}
        </button>
      </div>

      <MonthPanel.single_view :if={@single} single={@single} year_options={@year_options} />

      <MonthPanel.compare_view
        :if={@comparison}
        comparison={@comparison}
        year_options={@year_options}
      />
    </div>
    """
  end
end
