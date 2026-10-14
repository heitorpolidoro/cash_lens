defmodule CashLens.InstallmentsTenancyTest do
  @moduledoc """
  User B never reads, changes or links user A's installment groups or the
  transactions behind them.

  Calls made for B run with the process pinned to A on purpose: row-level
  security would then let A's rows through, so what keeps them out of B's
  results is only the application-level `Ownership.scope/2` filter.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Tenancy
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  @today Date.utc_today()
  @month Date.beginning_of_month(@today)

  setup do
    %{a: a, b: b} = cross_tenant()

    Tenancy.acting_as(a, fn ->
      card = account_fixture(%{user: a, is_credit_card: true, name: "A card"})

      tx = fn attrs ->
        transaction_fixture(
          Map.merge(%{user: a, account_id: card.id, date: @today, amount: "-100.00"}, attrs)
        )
      end

      # Parcels exist before the groups so that creating a group links them.
      tx.(%{description: "GELADEIRA"})
      tx.(%{description: "DYNAMICO", amount: "-77.00"})

      {:ok, group} =
        Installments.create_installment_group(a, %{
          description_pattern: "GELADEIRA",
          installments: 4,
          start_date: @month,
          total_amount: "400.00"
        })

      {:ok, dynamic} =
        Installments.create_installment_group(a, %{
          description_pattern: "DYNAMICO",
          installments: 2,
          start_date: @month
        })

      # A marker the scan would turn into a group, and a recurring debit the
      # suggestions would offer.
      scan = tx.(%{description: "LOJA X PARC 01/03", amount: "-50.00"})

      for amount <- ["-39.90", "-40.90", "-41.90"],
          do: tx.(%{description: "NETFLIX", amount: amount})

      parcel = Repo.get_by!(Transaction, description: "GELADEIRA")

      %{
        a: a,
        b: b,
        card: card,
        group: group,
        dynamic: Repo.get!(InstallmentGroup, dynamic.id),
        parcel: parcel,
        scan: scan
      }
    end)
  end

  # B's calls run while the process is pinned to A.
  defp as_b(a, fun), do: Tenancy.acting_as(a, fun)

  # A's persisted installment state, read as A.
  defp snapshot(a) do
    Tenancy.acting_as(a, fn ->
      {Repo.all(from t in Transaction, order_by: t.id),
       Repo.all(from g in InstallmentGroup, order_by: g.id)}
    end)
  end

  test "the fixtures give A a linked parcel", %{a: a, group: group, parcel: parcel} do
    assert parcel.installment_group_id == group.id
    assert [_, _] = Tenancy.acting_as(a, fn -> Installments.list_installment_groups(a) end)
  end

  describe "user B cannot read user A's groups" do
    test "lists, totals and projections are empty or zero", %{a: a, b: b, card: card} do
      as_b(a, fn ->
        assert Installments.list_installment_groups(b) == []
        assert Installments.list_account_groups(b, card.id) == []
        assert Installments.account_installment_groups(b, card.id, @month) == []
        assert Decimal.equal?(Installments.account_installment_total(b, card.id, @month), 0)
        assert Installments.list_off_card_groups(b) == []
        assert Installments.list_active_groups(b) == []
        assert Installments.upcoming_installments(b) == []

        assert Decimal.equal?(Installments.monthly_commitment(b, @month).total, 0)
        assert Decimal.equal?(Installments.outstanding_balance(b, @month).total, 0)
        assert %{total: total, items: []} = Installments.cash_flow_relief(b, @month, 12)
        assert Decimal.equal?(total, 0)

        projection = Installments.monthly_projection(b, @month, 6)
        assert length(projection) == 6
        assert Enum.all?(projection, &Decimal.equal?(&1.total, 0))
      end)
    end

    test "the owner still sees them", %{a: a, card: card} do
      Tenancy.acting_as(a, fn ->
        assert Installments.account_installment_groups(a, card.id, @month) != []
        assert Decimal.compare(Installments.monthly_commitment(a, @month).total, 0) == :gt
      end)
    end

    test "lookups raise or return nothing", %{a: a, b: b, group: group, dynamic: dynamic} do
      as_b(a, fn ->
        assert_raise Ecto.NoResultsError, fn ->
          Installments.get_installment_group!(b, group.id)
        end

        assert_raise Ecto.NoResultsError, fn ->
          Installments.get_group_with_progress(b, group.id)
        end

        assert Installments.list_group_transactions(b, group.id) == []
        assert Installments.find_matching_group(b, "GELADEIRA PARCELADA") == nil

        # No parcel of A's is visible, so nothing is inferred from them.
        assert %InstallmentGroup{total_amount: nil} = Installments.load_dynamic_fields(b, dynamic)
      end)

      Tenancy.acting_as(a, fn ->
        assert %InstallmentGroup{total_amount: %Decimal{}} =
                 Installments.load_dynamic_fields(a, dynamic)
      end)
    end

    test "commitment suggestions leave out A's recurring debits", %{a: a, b: b} do
      as_b(a, fn -> assert Installments.suggest_commitment_patterns(b) == [] end)

      Tenancy.acting_as(a, fn ->
        assert [%{description: "NETFLIX"}] = Installments.suggest_commitment_patterns(a)
      end)
    end
  end

  describe "user B cannot change user A's groups" do
    test "update and delete answer :not_found and leave A's rows unchanged", %{
      a: a,
      b: b,
      group: group
    } do
      before = snapshot(a)

      as_b(a, fn ->
        assert {:error, :not_found} =
                 Installments.update_installment_group(b, group, %{description_pattern: "HACKED"})

        assert {:error, :not_found} = Installments.delete_installment_group(b, group)
        assert {:error, :not_found} = Installments.associate_matching_transactions(b, group)
      end)

      assert snapshot(a) == before
    end

    test "scan and detect only read and write B's own rows", %{a: a, b: b, scan: scan} do
      before = snapshot(a)

      as_b(a, fn ->
        assert Installments.scan_and_apply_all(b) == 0
        assert Installments.detect_and_apply(b, [scan]) == 0
      end)

      assert snapshot(a) == before
    end

    test "scan for the owner does group the marker (the check above has teeth)", %{
      a: a,
      scan: scan
    } do
      Tenancy.acting_as(a, fn ->
        assert Installments.scan_and_apply_all(a) == 1
        assert %Transaction{installment_group_id: id} = Repo.get!(Transaction, scan.id)
        assert id
      end)
    end

    test "creating a group ignores a user_id in the attrs", %{a: a, b: b} do
      Tenancy.acting_as(b, fn ->
        assert {:ok, group} =
                 Installments.create_installment_group(b, %{
                   description_pattern: "B OWN",
                   installments: 2,
                   start_date: @month,
                   user_id: a.id
                 })

        assert group.user_id == b.id
      end)
    end
  end

  describe "transactions cannot point at someone else's rows" do
    test "an installment group or parent owned by A is a changeset error for B", %{
      a: a,
      b: b,
      group: group,
      parcel: parcel
    } do
      b_account = account_fixture(%{user: b})

      Tenancy.acting_as(b, fn ->
        assert {:error, changeset} =
                 Transactions.create_transaction(b, %{
                   account_id: b_account.id,
                   description: "B TX",
                   amount: "-1.00",
                   date: @today,
                   installment_group_id: group.id
                 })

        assert %{installment_group_id: ["does not exist"]} = errors_on(changeset)

        assert {:error, changeset} =
                 Transactions.create_transaction(b, %{
                   account_id: b_account.id,
                   description: "B TX 2",
                   amount: "-1.00",
                   date: @today,
                   parent_transaction_id: parcel.id
                 })

        assert %{parent_transaction_id: ["does not exist"]} = errors_on(changeset)
      end)

      Tenancy.acting_as(a, fn ->
        refute Repo.exists?(from t in Transaction, where: like(t.description, "B TX%"))
      end)
    end

    test "A may link its own transaction to its own group", %{a: a, card: card, group: group} do
      Tenancy.acting_as(a, fn ->
        assert {:ok, tx} =
                 Transactions.create_transaction(a, %{
                   account_id: card.id,
                   description: "OWN LINK",
                   amount: "-1.00",
                   date: @today,
                   installment_group_id: group.id
                 })

        assert tx.installment_group_id == group.id
      end)
    end
  end
end
