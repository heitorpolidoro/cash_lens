defmodule CashLens.ForecastScopeGuardTest do
  @moduledoc """
  Guards the boundary documented in `CashLens.Accounts.Scopes` on the forecast
  side: the `:estimado` credit-card bill occurrence must keep disclosing the
  installment groups behind it.

  `:estimado` is the only branch of `Forecast.card_occurrences/2` that calls
  `Installments.account_installment_groups/2`, the query a leaked cash-accounts
  scope would empty. The assertions deliberately target the disclosure rather
  than the bill amount: on this branch the estimate is
  `statement_amount + recent_installments - future_installments`, which is
  unchanged when both installment totals collapse to zero.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CreditCardsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Forecast
  alias CashLens.Installments

  @group_pattern "FORECAST_SCOPE_GUARD_GROUP"
  @due_day 10
  @parcel_count 24

  defp month_index(%Date{year: year, month: month}), do: year * 12 + month

  # Builds the fixture that forces the :estimado branch: an open credit-card
  # account with a billing cycle, one statement in the recent-history window but
  # in a past month (so `estimate_for_month/2` has an amount while the forecast
  # month itself has no statement), and one installment group whose transactions
  # sit on that card account and whose plan bills a parcel in the forecast month.
  defp estimado_fixture do
    today = Date.utc_today()
    due_date = Forecast.next_occurrence_date(@due_day, today)
    forecast_month = Date.beginning_of_month(due_date)

    card =
      account_fixture(%{
        is_credit_card: true,
        is_closed: false,
        closing_day: 1,
        due_day: @due_day
      })

    past_due_date = Date.add(today, -40)
    statement_fixture(%{account_id: card.id, due_date: past_due_date})

    group_start = Date.beginning_of_month(past_due_date)

    {:ok, group} =
      Installments.create_installment_group(%{
        description_pattern: @group_pattern,
        installments: @parcel_count,
        start_date: group_start,
        total_amount: Decimal.new("2400.00")
      })

    transaction_fixture(%{
      account_id: card.id,
      installment_group_id: group.id,
      date: group_start,
      amount: Decimal.new("-100.00")
    })

    expected_parcel_number = month_index(forecast_month) - month_index(group_start) + 1

    %{
      today: today,
      due_date: due_date,
      card: card,
      group: group,
      expected_parcel_number: expected_parcel_number
    }
  end

  test "the :estimado card occurrence still discloses installment groups on the card account" do
    ctx = estimado_fixture()

    occurrences = Forecast.card_occurrences(ctx.today, ctx.due_date)

    assert [occurrence] = occurrences
    assert occurrence.origin == :estimado

    expected_parcel = Installments.parcel_value(ctx.group)
    refute Decimal.equal?(expected_parcel, Decimal.new("0"))

    refute Decimal.equal?(occurrence.installment_total, Decimal.new("0"))
    assert Decimal.equal?(occurrence.installment_total, expected_parcel)

    disclosed =
      Enum.find(occurrence.installment_groups, &(&1.description == @group_pattern))

    assert disclosed, "the named installment group is missing from the occurrence disclosure"
    assert disclosed.id == ctx.group.id
    assert Decimal.equal?(disclosed.parcel_value, expected_parcel)
    assert disclosed.parcel_number == ctx.expected_parcel_number
  end
end
