defmodule CashLensWeb.MonthLive.MonthPanel do
  @moduledoc """
  Presentation components for the month closing screen (`/months/:year/:month`).

  Two mutually exclusive views are rendered from here:

    * `single_view/1` — one month in isolation: four KPI cards (opening balance,
      income, expenses, final balance with a surplus/deficit badge) plus the
      income and expense breakdowns by category, each with its share of the
      month's total and a progress bar.

    * `compare_view/1` — two months side by side, always chronological: the base
      (older) month on the left and the analysed (newer) month on the right, the
      latter carrying the `+/- R$` difference against the former. The comparison
      is deliberately operational: net result and category movement only, never
      accumulated account balances.
  """
  use CashLensWeb, :html

  @month_numbers 1..12

  attr :single, :map, required: true
  attr :year_options, :list, required: true

  def single_view(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <.period_selector
          scope="single"
          year={@single.year}
          month={@single.month}
          year_options={@year_options}
          blocked={%{}}
        />

        <.link
          navigate={~p"/transactions?month=#{@single.month}&year=#{@single.year}"}
          class="text-xs text-blue-600 font-bold hover:underline self-center"
        >
          Ver todas as transações ({month_label(@single.month)}/{@single.year}) →
        </.link>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div class="bg-white border border-slate-200 rounded-2xl p-5 shadow-sm">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">
            Saldo de Abertura
          </span>
          <div class="text-2xl font-black text-blue-600 mt-2">
            {format_currency(@single.opening_balance)}
          </div>
          <div class="text-xs text-slate-400 mt-1">
            Total em 01/{pad_month(@single.month)}/{@single.year}
          </div>
        </div>

        <div class="bg-white border border-slate-200 rounded-2xl p-5 shadow-sm">
          <span class="text-xs font-bold uppercase tracking-wider text-teal-600">Receitas</span>
          <div class="text-2xl font-black text-teal-600 mt-2">
            {format_currency(@single.income_total)}
          </div>
          <div class="text-xs text-slate-400 mt-1">
            {length(@single.income_rows)} categorias
          </div>
        </div>

        <div class="bg-white border border-slate-200 rounded-2xl p-5 shadow-sm">
          <span class="text-xs font-bold uppercase tracking-wider text-rose-500">Despesas</span>
          <div class="text-2xl font-black text-rose-500 mt-2">
            {format_currency(@single.expense_total)}
          </div>
          <div class="text-xs text-slate-400 mt-1">
            {length(@single.expense_rows)} categorias
          </div>
        </div>

        <div class="bg-white border border-slate-200 rounded-2xl p-5 shadow-sm bg-gradient-to-br from-white to-blue-50/40">
          <div class="flex items-center justify-between gap-2">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">
              Saldo Final
            </span>
            <span class={[
              "text-[10px] font-bold px-2 py-0.5 rounded-md border whitespace-nowrap",
              if(positive?(@single.net),
                do: "bg-emerald-50 text-emerald-700 border-emerald-200",
                else: "bg-rose-50 text-rose-700 border-rose-200"
              )
            ]}>
              {if positive?(@single.net), do: "Superávit: ", else: "Déficit: "}{format_delta(
                @single.net
              )}
            </span>
          </div>
          <div class="text-2xl font-black text-blue-600 mt-2">
            {format_currency(@single.final_balance)}
          </div>
          <div class="text-xs text-slate-400 mt-1">Total consolidado das contas</div>
        </div>
      </div>

      <.single_table
        title="Receitas por Categoria"
        empty_msg="Nenhuma receita registrada neste mês."
        rows={@single.income_rows}
        type="credit"
        amount_class="text-teal-600"
        bar_class="bg-teal-500"
        expanded={@single.expanded}
        transactions={@single.transactions}
      />

      <.single_table
        title="Gastos por Categoria"
        empty_msg="Nenhuma despesa registrada neste mês."
        rows={@single.expense_rows}
        type="debit"
        amount_class="text-rose-500"
        bar_class="bg-blue-500"
        expanded={@single.expanded}
        transactions={@single.transactions}
      />
    </div>
    """
  end

  attr :comparison, :map, required: true
  attr :year_options, :list, required: true

  def compare_view(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="bg-blue-50/60 border border-blue-100 rounded-xl px-4 py-2.5 flex flex-col sm:flex-row sm:items-center justify-between gap-2 text-xs text-blue-900">
        <div class="flex items-center gap-2">
          <span class="font-bold">Modo de Comparação Ativo:</span>
          <span>Compare mês a mês ou o mesmo mês em anos diferentes.</span>
        </div>
        <span class="text-[11px] font-medium text-blue-700 bg-white px-2 py-0.5 rounded border border-blue-200 self-start sm:self-auto">
          Diferença = Mês em Análise (Direita) − Mês Base (Esquerda)
        </span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 items-start">
        <.compare_panel
          side="base"
          label="Mês Base (Referência)"
          label_class="text-slate-400"
          panel_class="border-slate-200"
          period={@comparison.base}
          comparison={@comparison}
          year_options={@year_options}
        />

        <.compare_panel
          side="analysis"
          label="Mês em Análise (Foco)"
          label_class="text-blue-600"
          panel_class="border-2 border-blue-500/30"
          period={@comparison.analysis}
          comparison={@comparison}
          year_options={@year_options}
        />
      </div>
    </div>
    """
  end

  attr :side, :string, required: true
  attr :label, :string, required: true
  attr :label_class, :string, required: true
  attr :panel_class, :string, required: true
  attr :period, :map, required: true
  attr :comparison, :map, required: true
  attr :year_options, :list, required: true

  defp compare_panel(assigns) do
    ~H"""
    <div class={["bg-white border rounded-2xl shadow-sm p-5 space-y-6", @panel_class]}>
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-4 border-b border-slate-100">
        <div>
          <span class={[
            "text-[10px] font-extrabold uppercase tracking-wider block",
            @label_class
          ]}>
            {@label}
          </span>
          <.period_selector
            scope={@side}
            year={@period.year}
            month={@period.month}
            year_options={@year_options}
            blocked={@comparison.blocked[@side]}
          />
        </div>

        <div class="sm:text-right">
          <span class="text-[9px] font-extrabold uppercase tracking-wider text-slate-400 block">
            Resultado Líquido
          </span>
          <div class="flex items-baseline sm:justify-end gap-3 mt-0.5">
            <span class={[
              "text-sm font-mono font-black",
              if(positive?(@period.net), do: "text-teal-600", else: "text-rose-500")
            ]}>
              {format_delta(@period.net)}
            </span>
            <span
              :if={@side == "analysis"}
              class={["text-xs font-mono font-bold", delta_class(@comparison.net_delta, :up_good)]}
            >
              {format_delta(@comparison.net_delta)}
            </span>
          </div>
        </div>
      </div>

      <.compare_table
        side={@side}
        section="income"
        title="Receitas por Categoria"
        total_label="Total Receitas"
        empty_msg="Nenhuma receita registrada neste mês."
        rows={@comparison.income_rows}
        total={@period.income_total}
        delta={@comparison.income_delta}
        amount_class="text-teal-600"
        bar_class="bg-teal-500"
        polarity={:up_good}
      />

      <.compare_table
        side={@side}
        section="expense"
        title="Gastos por Categoria"
        total_label="Total Gastos"
        empty_msg="Nenhuma despesa registrada neste mês."
        rows={@comparison.expense_rows}
        total={@period.expense_total}
        delta={@comparison.expense_delta}
        amount_class="text-rose-500"
        bar_class="bg-blue-500"
        polarity={:down_good}
      />
    </div>
    """
  end

  attr :side, :string, required: true
  attr :section, :string, required: true
  attr :title, :string, required: true
  attr :total_label, :string, required: true
  attr :empty_msg, :string, required: true
  attr :rows, :list, required: true
  attr :total, :any, required: true
  attr :delta, :any, required: true
  attr :amount_class, :string, required: true
  attr :bar_class, :string, required: true
  attr :polarity, :atom, required: true

  defp compare_table(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-center justify-between pb-1 border-b border-slate-100 gap-3">
        <div>
          <h3 class="font-extrabold uppercase tracking-tight text-[11px] text-slate-700">
            {@title}
          </h3>
          <span class="text-[10px] text-slate-400 font-medium">{length(@rows)} categorias</span>
        </div>
        <div class="text-right">
          <span class="text-[9px] font-bold text-slate-400 uppercase tracking-wider block">
            {@total_label}
          </span>
          <div class="flex items-baseline justify-end gap-3 mt-0.5">
            <span class={["font-mono font-bold text-xs", @amount_class]}>
              {format_currency(@total)}
            </span>
            <span
              :if={@side == "analysis"}
              class={["font-mono font-bold text-xs", delta_class(@delta, @polarity)]}
            >
              {format_delta(@delta)}
            </span>
          </div>
        </div>
      </div>

      <p :if={@rows == []} class="py-6 text-center text-xs text-slate-400">{@empty_msg}</p>

      <table :if={@rows != []} class="w-full text-xs text-left">
        <thead class="bg-slate-50/50 border-b border-slate-100 text-slate-500 font-bold text-[10px]">
          <tr>
            <th class="py-2">Categoria</th>
            <th class="py-2 text-right">Valor</th>
            <th class="py-2 text-right w-20">% total</th>
            <th :if={@side == "analysis"} class="py-2 text-right w-24">Diferença</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-100">
          <tr
            :for={row <- @rows}
            id={"#{@side}-#{@section}-row-#{row.category_id || "nil"}"}
            class={zero?(side_total(row, @side)) && "opacity-40"}
          >
            <td class="py-2.5">
              <span class="font-semibold text-slate-800">{row.name}</span>
              <.category_tag section={@section} type={row.type} />
            </td>
            <td class={["py-2.5 text-right font-mono font-medium", @amount_class]}>
              {format_currency(side_total(row, @side))}
            </td>
            <td class="py-2.5 text-right">
              <.percentage_bar pct={side_pct(row, @side)} bar_class={@bar_class} width_class="w-12" />
            </td>
            <td :if={@side == "analysis"} class="py-2.5 text-right">
              <span class={["font-mono font-bold text-[11px]", delta_class(row.delta, @polarity)]}>
                {format_delta(row.delta)}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :empty_msg, :string, required: true
  attr :rows, :list, required: true
  attr :type, :string, required: true
  attr :amount_class, :string, required: true
  attr :bar_class, :string, required: true
  attr :expanded, :any, required: true
  attr :transactions, :map, required: true

  defp single_table(assigns) do
    ~H"""
    <div class="bg-white border border-slate-200 rounded-2xl shadow-sm overflow-hidden">
      <div class="px-6 py-4 border-b border-slate-100 flex items-center justify-between">
        <h2 class="font-extrabold uppercase tracking-tight text-xs text-slate-800">{@title}</h2>
        <span class="text-xs text-slate-400 font-medium">{length(@rows)} categorias</span>
      </div>

      <p :if={@rows == []} class="px-6 py-12 text-center text-sm text-slate-400">{@empty_msg}</p>

      <table :if={@rows != []} class="w-full text-xs text-left">
        <thead class="bg-slate-50/50 border-b border-slate-100 text-slate-500 font-bold text-[11px]">
          <tr>
            <th class="py-2.5 px-6">Categoria</th>
            <th class="py-2.5 px-4 text-right">Valor</th>
            <th class="py-2.5 px-6 text-right w-56">% do total</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-100">
          <%= for row <- @rows do %>
            <% row_key = "#{@type}:#{row.category_id || "nil"}" %>
            <% open? = MapSet.member?(@expanded, row_key) %>
            <tr
              class="hover:bg-slate-50/60 transition cursor-pointer select-none"
              phx-click="toggle_category"
              phx-value-category_id={row_key}
            >
              <td class="py-3 px-6">
                <div class="flex items-center gap-2">
                  <span class="text-slate-400 text-[10px] font-mono">
                    {if open?, do: "⌄", else: "›"}
                  </span>
                  <div>
                    <span class="font-semibold text-slate-800">{row.name}</span>
                    <.category_tag
                      section={if @type == "credit", do: "income", else: "expense"}
                      type={row.type}
                    />
                  </div>
                </div>
              </td>
              <td class={["py-3 px-4 text-right font-mono font-medium", @amount_class]}>
                {format_currency(row.total)}
              </td>
              <td class="py-3 px-6 text-right">
                <.percentage_bar pct={row.pct} bar_class={@bar_class} width_class="w-28" />
              </td>
            </tr>
            <.transactions_row :if={open?} transactions={Map.get(@transactions, row_key, [])} />
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :transactions, :list, required: true

  defp transactions_row(assigns) do
    ~H"""
    <tr>
      <td colspan="3" class="p-0 bg-slate-50/60">
        <p :if={@transactions == []} class="px-10 py-3 text-xs text-slate-400 italic">
          Nenhuma transação encontrada.
        </p>
        <table :if={@transactions != []} class="w-full text-xs">
          <tbody class="divide-y divide-slate-100">
            <tr :for={t <- @transactions} class="hover:bg-white/60">
              <td class="pl-10 py-2 w-24 font-mono text-slate-400 whitespace-nowrap">
                {Calendar.strftime(t.date, "%d")} {month_label(t.date.month)}
              </td>
              <td class="py-2 truncate max-w-xs">
                <div class="font-medium text-slate-700">{t.description}</div>
                <div :if={t.category} class="text-[9px] text-slate-400 uppercase tracking-wider">
                  {t.category.name}
                </div>
              </td>
              <td class={[
                "py-2 pr-6 text-right font-mono whitespace-nowrap",
                if(Decimal.lt?(t.amount, 0), do: "text-rose-500", else: "text-teal-600")
              ]}>
                {format_currency(t.amount)}
              </td>
            </tr>
          </tbody>
        </table>
      </td>
    </tr>
    """
  end

  attr :section, :string, required: true
  attr :type, :any, required: true

  defp category_tag(assigns) do
    ~H"""
    <span
      :if={@section == "income"}
      class="text-[9px] font-bold uppercase tracking-wider text-teal-600 block mt-0.5"
    >
      receita
    </span>
    <span
      :if={@section != "income" and not is_nil(@type)}
      class={[
        "text-[9px] font-bold uppercase tracking-wider block mt-0.5",
        if(@type == "fixed", do: "text-blue-600", else: "text-amber-600")
      ]}
    >
      {@type}
    </span>
    <span
      :if={@section != "income" and is_nil(@type)}
      class="text-[9px] uppercase tracking-wider text-slate-300 block mt-0.5"
    >
      sem categoria
    </span>
    """
  end

  attr :pct, :any, required: true
  attr :bar_class, :string, required: true
  attr :width_class, :string, required: true

  defp percentage_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-end gap-2">
      <div class={[@width_class, "bg-slate-100 rounded-full h-1.5 overflow-hidden"]}>
        <div
          class={[@bar_class, "h-1.5 rounded-full"]}
          style={"width: #{min(Decimal.to_float(@pct), 100)}%"}
        >
        </div>
      </div>
      <span class="w-12 text-right text-slate-500">{@pct}%</span>
    </div>
    """
  end

  @doc """
  Renders the decoupled `< [Ano] >` / `< [Mês] >` controls for one period.

  `blocked` carries the moves that would break the comparison's chronological
  order (`:prev_year`, `:next_year`, `:prev_month`, `:next_month`); those arrows
  render disabled. In single-month mode nothing is ever blocked.
  """
  attr :scope, :string, required: true
  attr :year, :integer, required: true
  attr :month, :integer, required: true
  attr :year_options, :list, required: true
  attr :blocked, :map, required: true

  def period_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mt-1">
      <div class="flex items-center bg-white border border-slate-200 rounded-xl p-0.5 shadow-sm">
        <.nav_arrow scope={@scope} unit="year" dir="-1" blocked={@blocked[:prev_year]} />
        <form id={"#{@scope}-year-form"} phx-change="select_period">
          <input type="hidden" name="scope" value={@scope} />
          <select
            name="year"
            class="appearance-none bg-transparent font-bold text-xs text-slate-700 py-1 px-2 cursor-pointer focus:outline-none"
          >
            <option :for={year <- @year_options} value={year} selected={year == @year}>
              {year}
            </option>
          </select>
        </form>
        <.nav_arrow scope={@scope} unit="year" dir="1" blocked={@blocked[:next_year]} />
      </div>

      <span class="text-slate-300 font-mono">/</span>

      <div class="flex items-center bg-white border border-slate-200 rounded-xl p-0.5 shadow-sm">
        <.nav_arrow scope={@scope} unit="month" dir="-1" blocked={@blocked[:prev_month]} />
        <form id={"#{@scope}-month-form"} phx-change="select_period">
          <input type="hidden" name="scope" value={@scope} />
          <select
            name="month"
            class="appearance-none bg-transparent font-extrabold text-sm text-slate-900 py-1 px-2 cursor-pointer focus:outline-none"
          >
            <option :for={month <- month_numbers()} value={month} selected={month == @month}>
              {month_name(month)}
            </option>
          </select>
        </form>
        <.nav_arrow scope={@scope} unit="month" dir="1" blocked={@blocked[:next_month]} />
      </div>
    </div>
    """
  end

  attr :scope, :string, required: true
  attr :unit, :string, required: true
  attr :dir, :string, required: true
  attr :blocked, :any, required: true

  defp nav_arrow(assigns) do
    assigns = assign(assigns, :direction, if(assigns.dir == "-1", do: "prev", else: "next"))

    ~H"""
    <button
      type="button"
      id={"#{@scope}-#{@direction}-#{@unit}"}
      phx-click="nav"
      phx-value-scope={@scope}
      phx-value-unit={@unit}
      phx-value-dir={@dir}
      disabled={@blocked == true}
      aria-label={arrow_label(@direction, @unit)}
      class={[
        "p-1.5 rounded-lg text-slate-600 transition",
        (@blocked == true && "opacity-30 cursor-not-allowed") || "hover:bg-slate-50"
      ]}
    >
      <.icon
        name={if @direction == "prev", do: "hero-chevron-left", else: "hero-chevron-right"}
        class="size-3.5"
      />
    </button>
    """
  end

  defp arrow_label("prev", "year"), do: "Ano anterior"
  defp arrow_label("next", "year"), do: "Próximo ano"
  defp arrow_label("prev", "month"), do: "Mês anterior"
  defp arrow_label("next", "month"), do: "Próximo mês"

  defp side_total(row, "base"), do: row.base_total
  defp side_total(row, _analysis), do: row.analysis_total

  defp side_pct(row, "base"), do: row.base_pct
  defp side_pct(row, _analysis), do: row.analysis_pct

  defp zero?(value), do: Decimal.equal?(value, 0)

  defp positive?(value), do: not Decimal.negative?(value)

  # Signed, Brazilian-style money used for deltas and net results:
  # "+R$ 1.234,56", "-R$ 1.234,56" or "R$ 0,00".
  defp format_delta(value) do
    cond do
      Decimal.equal?(value, 0) -> "R$ 0,00"
      Decimal.negative?(value) -> "-" <> format_currency(Decimal.abs(value))
      true -> "+" <> format_currency(value)
    end
  end

  # Income and expenses read the same number in opposite directions: earning more
  # is good, spending more is not.
  defp delta_class(value, polarity) do
    cond do
      Decimal.equal?(value, 0) -> "text-slate-400"
      Decimal.negative?(value) == (polarity == :down_good) -> "text-emerald-600"
      true -> "text-rose-500"
    end
  end

  defp pad_month(month), do: String.pad_leading(to_string(month), 2, "0")

  defp month_numbers, do: @month_numbers
end
