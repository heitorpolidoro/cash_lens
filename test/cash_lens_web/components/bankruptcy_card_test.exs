defmodule CashLensWeb.BankruptcyCardTest do
  use CashLensWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CashLensWeb.BankruptcyCard

  @today ~D[2026-10-09]

  defp render_band(zero_date, opts \\ []) do
    trough = Keyword.get(opts, :trough, false)
    sigma = Keyword.get(opts, :sigma, Decimal.new("100.00"))

    render_component(&BankruptcyCard.bankruptcy_card/1,
      bankruptcy: BankruptcyCard.status(zero_date, @today),
      trough: trough,
      volatility: %{sigma: sigma, months: 6},
      final_balance: Decimal.new("5000.00")
    )
  end

  # The scale only exists if every band is a different card. Asserting the fill
  # of one band says nothing about the other three being painted at all --
  # which is how three of them sat white while the code looked finished.
  describe "the whole card carries the severity" do
    test "safe is green" do
      html = render_band(nil)
      assert html =~ "bg-success/10"
      assert html =~ "border-success/40"
      refute html =~ "bg-warning"
      refute html =~ "bg-error"
    end

    test "distant is amber" do
      html = render_band(Date.add(@today, 200))
      assert html =~ "bg-warning/15"
      assert html =~ "border-warning/50"
      refute html =~ "bg-error"
    end

    test "near is a stronger amber, not the same tint as distant" do
      html = render_band(Date.add(@today, 90))
      assert html =~ "bg-warning/45"
      assert html =~ "border-warning/90"
      refute html =~ "bg-warning/15"
    end

    test "critical stays a solid red" do
      html = render_band(Date.add(@today, 30))
      assert html =~ "bg-error border-error text-error-content"
    end
  end

  # Ink on its own tint is the failure the scale invites: amber on amber, red
  # on red. The theme has no darker amber -- `warning-content` is the near-white
  # for a solid fill -- so the tinted bands drop the hue entirely.
  describe "the figure and the badge stay legible on the tint" do
    test "no tinted band writes the figure in its own hue" do
      for zero_date <- [nil, Date.add(@today, 200), Date.add(@today, 90)] do
        html = render_band(zero_date)
        refute html =~ "text-warning\""
        refute html =~ "text-error\""
        assert html =~ "text-base-content"
      end
    end

    test "near's badge is not amber on amber" do
      html = render_band(Date.add(@today, 90))
      assert html =~ "badge-neutral"
      refute html =~ "badge-warning"
    end

    test "critical writes its figure in the ink meant for a solid fill" do
      html = render_band(Date.add(@today, 30))
      assert html =~ "text-error-content"
      refute html =~ "text-base-content"
    end
  end

  describe "a fragile projection is not a safe one" do
    test "a thin trough paints the card amber although nothing crosses zero" do
      html =
        render_band(nil,
          trough: %{balance: Decimal.new("50.00"), date: ~D[2026-12-02]},
          sigma: Decimal.new("900.00")
        )

      assert html =~ "bg-warning/15"
      refute html =~ "bg-success/10"
      assert html =~ "Pode zerar"
      # The warning rode in amber ink, which is now the colour behind it.
      refute html =~ "text-warning"
    end

    test "a trough wider than the monthly swing leaves the card green" do
      html =
        render_band(nil,
          trough: %{balance: Decimal.new("9000.00"), date: ~D[2026-12-02]},
          sigma: Decimal.new("900.00")
        )

      assert html =~ "bg-success/10"
      assert html =~ "Seguro"
      refute html =~ "Pode zerar"
    end
  end
end
