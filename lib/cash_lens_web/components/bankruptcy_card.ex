defmodule CashLensWeb.BankruptcyCard do
  @moduledoc """
  The "Projeção de Falência" card: when the projected balance runs out, or how
  thin it gets if it never does.

  It lives here rather than in the forecast screen because the dashboard shows
  it too, and it is not a figure that can be copied: the headline swaps between
  a date, the trough and the final balance; the severity colours the whole card;
  and a projection that never crosses zero can still be fragile, which is a
  separate warning. Two renderings of that would drift, and the one on the
  dashboard would be the one that drifted wrong.
  """
  use CashLensWeb, :html

  # Where the bands fall. `:near` is the quarter ahead, `:critical` the two
  # months you cannot plan your way out of.
  @near_days 120
  @critical_days 60

  @doc """
  Everything the card needs, derived from a projection.

  One projection serves both screens: the slice a 30-day caller reads out of a
  365-day projection is the same slice, so nothing is gained by building two.
  """
  def assigns_from(user, projection, horizon_days, today \\ Date.utc_today()) do
    %{
      bankruptcy: status(projection.zero_date, today),
      # Only meaningful while the curve stays above zero: once it crosses, the
      # crossing is the worst news and the trough is just a point past it.
      trough: projection.zero_date == nil && CashLens.Forecast.trough(projection, horizon_days),
      volatility: CashLens.Forecast.monthly_volatility(user),
      final_balance: CashLens.Forecast.final_balance(projection)
    }
  end

  @doc """
  Classifies how close the projection puts us to running out of money.

  Public so the band boundaries can be asserted exactly. Driving them through a
  whole projection would make the test depend on the day of the month it runs
  on, since occurrences fall on a `day_of_month` rather than a chosen offset.
  """
  def status(nil, _today), do: %{date: nil, days: nil, severity: :safe}

  def status(zero_date, today) do
    days = Date.diff(zero_date, today)

    severity =
      cond do
        days > @near_days -> :distant
        days >= @critical_days -> :near
        true -> :critical
      end

    %{date: zero_date, days: days, severity: severity}
  end

  attr :bankruptcy, :map, required: true
  attr :trough, :any, required: true
  attr :volatility, :any, required: true
  attr :final_balance, :any, required: true
  attr :navigate, :string, default: nil

  @doc """
  Renders the card. With `navigate`, the whole card is the link to the screen
  that explains it -- a figure this alarming should not be a dead end.
  """
  def bankruptcy_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "card border shadow-sm rounded-2xl p-5 block",
        @navigate && "hover:shadow-md transition cursor-pointer",
        card_class(@bankruptcy, fragile?(@trough, @volatility))
      ]}
      data-role="kpi-bankruptcy"
      data-severity={@bankruptcy.severity}
    >
      <%!--
        The badge rides with the label, not with the figure. Beside a full date
        it had nowhere to go in a narrow column and wrapped into two cramped
        lines over the number it was qualifying.
      --%>
      <div class="flex items-center justify-between gap-2">
        <span class={[
          "text-[11px] font-black uppercase tracking-wider",
          if(@bankruptcy.severity == :critical, do: "opacity-80", else: "opacity-50")
        ]}>
          Projeção de Falência
        </span>
        <span class={[
          "badge badge-sm text-[10px] font-black whitespace-nowrap shrink-0",
          badge_class(@bankruptcy, fragile?(@trough, @volatility))
        ]}>
          {badge_label(@bankruptcy, fragile?(@trough, @volatility))}
        </span>
      </div>
      <div class="mt-1">
        <span class={[
          "text-2xl font-black",
          figure_class(@bankruptcy, fragile?(@trough, @volatility))
        ]}>
          {cond do
            @bankruptcy.date -> format_date(@bankruptcy.date)
            @trough -> format_currency(@trough.balance)
            true -> format_currency(@final_balance)
          end}
        </span>
      </div>
      <span class={[
        "text-[11px] font-medium mt-1 block",
        if(@bankruptcy.severity == :critical, do: "opacity-90", else: "opacity-60")
      ]}>
        {caption(@bankruptcy, @trough)}
      </span>
      <span
        :if={fragile?(@trough, @volatility)}
        data-role="volatility-warning"
        class="text-[11px] font-bold opacity-80 mt-1 block"
      >
        Pode zerar: a folga é menor que a variação mensal típica
        (±{format_currency(@volatility.sigma)} em {@volatility.months} meses).
      </span>
    </.link>
    """
  end

  # The whole card carries the severity, as one scale: green, amber, strong
  # amber, red. The theme's `warning` is already an orange hue, so the strong
  # step reads as orange without bringing a colour in from outside the theme.
  #
  # A fragile `:safe` takes the amber of `:distant`: it is not safe, and the
  # card would otherwise be green while its own badge said "Pode zerar".
  defp card_class(%{severity: :critical}, _fragile),
    do: "bg-error border-error text-error-content"

  defp card_class(%{severity: :near}, _fragile), do: "bg-warning/75 border-warning"
  defp card_class(%{severity: :distant}, _fragile), do: "bg-warning/15 border-warning/50"
  defp card_class(%{severity: :safe}, true), do: "bg-warning/15 border-warning/50"
  defp card_class(%{severity: :safe}, _solid), do: "bg-success/10 border-success/40"

  # The figure's ink has to clear the tint behind it, and the tint is now the
  # hue the ink used to be: `text-warning` on `bg-warning/75` is amber on amber,
  # and the theme has no darker amber to fall back on -- its `warning-content`
  # is the near-white meant for a solid amber fill. So every tinted band drops
  # the hue and reads the figure in `base-content`. The card and the badge
  # already say which band it is; the number's job is to be read.
  defp figure_class(%{severity: :critical}, _fragile), do: "text-error-content"
  defp figure_class(_severity, _fragile), do: "text-base-content"

  # A projection that never crosses zero is only as safe as its thinnest moment.
  # When the trough is smaller than how much an ordinary month swings, the line
  # staying positive says more about the model drawing one line than about the
  # money being there.
  defp fragile?(%{balance: balance}, %{sigma: sigma}),
    do: Decimal.positive?(balance) and Decimal.lt?(balance, sigma)

  defp fragile?(_trough, _volatility), do: false

  defp badge_class(%{severity: :safe}, true), do: "badge-warning"
  defp badge_class(%{severity: :safe}, _solid), do: "badge-success"
  defp badge_class(%{severity: :distant}, _fragile), do: "badge-warning"
  defp badge_class(%{severity: :near}, _fragile), do: "badge-neutral"
  defp badge_class(%{severity: :critical}, _fragile), do: "badge-neutral"

  defp badge_label(%{severity: :safe}, true), do: "Pode zerar"
  defp badge_label(%{severity: :safe}, _solid), do: "Seguro"
  defp badge_label(%{severity: :distant}, _fragile), do: "Atenção"
  defp badge_label(%{severity: :near}, _fragile), do: "Em risco"
  defp badge_label(%{severity: :critical}, _fragile), do: "Crítico"

  # The headline figure is the trough's amount, so the caption carries its date:
  # together they say how little is left on the worst day and when that day is.
  defp caption(%{severity: :safe}, %{date: %Date{} = date}),
    do: "Menor saldo em #{format_date(date)} · não zera em 12 meses"

  defp caption(%{severity: :safe}, _no_trough), do: "Não zera em 12 meses"

  defp caption(%{days: days}, _trough) when days <= 0,
    do: "Saldo já está zerado ou negativo"

  defp caption(%{days: 1}, _trough), do: "Saldo zera em 1 dia"
  defp caption(%{days: days}, _trough), do: "Saldo zera em #{days} dias"
end
