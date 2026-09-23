defmodule CashLens.InstallmentsScopeGuardTest do
  @moduledoc """
  Guards the boundary documented in `CashLens.Accounts.Scopes`: the Installments
  context must keep seeing credit-card accounts.

  Every installment-linked transaction in the production database sits on a
  credit-card account, so a cash-accounts scope leaking into any query these
  functions depend on would silently return empty groups and zero totals — and
  silently empty the forecast's installment disclosure with it.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments

  @month ~D[2026-07-01]

  defp card_group_fixture do
    card = account_fixture(%{is_credit_card: true})

    {:ok, group} =
      Installments.create_installment_group(%{
        description_pattern: "SCOPE_GUARD_CARD_GROUP",
        installments: 4,
        start_date: ~D[2026-06-01],
        total_amount: Decimal.new("400.00")
      })

    transaction_fixture(%{
      account_id: card.id,
      installment_group_id: group.id,
      date: ~D[2026-06-01],
      amount: Decimal.new("-100.00")
    })

    {card, group}
  end

  test "account_installment_groups/2 still returns a group living on a credit-card account" do
    {card, group} = card_group_fixture()

    ids = Installments.account_installment_groups(card.id, @month) |> Enum.map(& &1.id)

    assert group.id in ids
  end

  test "account_installment_total/2 returns the non-zero parcel sum of the card group" do
    {card, group} = card_group_fixture()

    total = Installments.account_installment_total(card.id, @month)
    expected = Installments.parcel_value(group)

    refute Decimal.equal?(total, Decimal.new("0"))
    assert Decimal.equal?(total, expected)
  end

  test "parcel_value/1 returns the group's non-zero parcel value" do
    {_card, group} = card_group_fixture()

    parcel = Installments.parcel_value(group)

    refute Decimal.equal?(parcel, Decimal.new("0"))
    assert Decimal.equal?(parcel, Decimal.new("100.00"))
  end
end
