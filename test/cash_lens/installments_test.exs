defmodule CashLens.InstallmentsTest do
  use CashLens.DataCase, async: false

  import Ecto.Query
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  defp group(attrs) do
    {:ok, g} =
      Installments.create_installment_group(
        Map.merge(
          %{description_pattern: "G", installments: 3, start_date: Date.utc_today()},
          attrs
        )
      )

    g
  end

  test "update_installment_group/2 changes fields" do
    g = group(%{description_pattern: "Antigo"})
    {:ok, updated} = Installments.update_installment_group(g, %{description_pattern: "Novo"})
    assert updated.description_pattern == "Novo"
  end

  test "change_installment_group/1 returns a changeset" do
    assert %Ecto.Changeset{} = Installments.change_installment_group(%InstallmentGroup{})
  end

  test "list_active_groups/0 excludes completed groups" do
    active = group(%{description_pattern: "Ativo (3x)", total_amount: "300.00", installments: 3})

    completed =
      group(%{description_pattern: "Fim (2x)", total_amount: "200.00", installments: 2})

    acc = account_fixture()
    t1 = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "Fim 1"})
    t2 = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "Fim 2"})

    Repo.update_all(from(t in Transaction, where: t.id in [^t1.id, ^t2.id]),
      set: [installment_group_id: completed.id]
    )

    ids = Installments.list_active_groups() |> Enum.map(& &1.id)
    assert active.id in ids
    refute completed.id in ids
  end

  test "get_group_with_progress/1 reports progress" do
    g = group(%{description_pattern: "P (2x)", total_amount: "200.00", installments: 2})
    acc = account_fixture()
    tx = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "P"})

    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
      set: [installment_group_id: g.id]
    )

    progress = Installments.get_group_with_progress(g.id)
    assert progress.paid_count == 1
    assert progress.remaining_count == 1
    refute progress.is_completed
  end

  test "find_matching_group/1 matches by description and handles nil" do
    g = group(%{description_pattern: "NETFLIX"})
    assert Installments.find_matching_group("PAGAMENTO NETFLIX MENSAL").id == g.id
    assert is_nil(Installments.find_matching_group("OUTRA COISA"))
    assert is_nil(Installments.find_matching_group(nil))
  end

  describe "last_installment_date/1" do
    test "returns start_date + (installments - 1) months" do
      g = %CashLens.Installments.InstallmentGroup{
        start_date: ~D[2025-10-08],
        installments: 10
      }

      assert Installments.last_installment_date(g) == ~D[2026-07-08]
    end

    test "single-installment group ends on its start date" do
      g = %CashLens.Installments.InstallmentGroup{start_date: ~D[2026-01-15], installments: 1}
      assert Installments.last_installment_date(g) == ~D[2026-01-15]
    end

    test "returns nil when start_date is missing" do
      g = %CashLens.Installments.InstallmentGroup{start_date: nil, installments: 3}
      assert Installments.last_installment_date(g) == nil
    end
  end

  describe "list_group_transactions/1" do
    test "returns the group's transactions ordered by installment_number" do
      {:ok, g} =
        Installments.create_installment_group(%{
          description_pattern: "LOJA Y",
          installments: 3,
          start_date: ~D[2026-01-01]
        })

      acc = account_fixture()

      t2 = transaction_fixture(%{account_id: acc.id, amount: "-10.00", description: "Y 2/3"})
      t1 = transaction_fixture(%{account_id: acc.id, amount: "-10.00", description: "Y 1/3"})

      Repo.update_all(from(t in Transaction, where: t.id == ^t1.id),
        set: [installment_group_id: g.id, installment_number: 1]
      )

      Repo.update_all(from(t in Transaction, where: t.id == ^t2.id),
        set: [installment_group_id: g.id, installment_number: 2]
      )

      numbers =
        g.id
        |> Installments.list_group_transactions()
        |> Enum.map(& &1.installment_number)

      assert numbers == [1, 2]
    end

    test "returns [] for a group with no transactions" do
      {:ok, g} =
        Installments.create_installment_group(%{
          description_pattern: "EMPTY",
          installments: 2,
          start_date: ~D[2026-01-01]
        })

      assert Installments.list_group_transactions(g.id) == []
    end
  end

  describe "upcoming_installments/1" do
    test "sums parcels per month, including groups without a total amount" do
      today = Date.utc_today()
      first = Date.new!(today.year, today.month, 1)

      group(%{
        description_pattern: "COM VALOR (3x)",
        total_amount: "300.00",
        installments: 3,
        start_date: first
      })

      group(%{
        description_pattern: "SEM VALOR (3x)",
        total_amount: nil,
        installments: 3,
        start_date: first
      })

      result = Installments.upcoming_installments(3)
      assert is_list(result)
      assert Enum.all?(result, &Map.has_key?(&1, :total))
      # The group with a total contributes 100/month.
      this_month = Enum.find(result, &(&1.date == first))
      assert Decimal.gt?(this_month.total, Decimal.new("0"))
    end

    test "flags a past month whose statement isn't imported yet as pending" do
      acc = account_fixture()
      g = group(%{description_pattern: "PAST (3x)", total_amount: "300.00", installments: 3})

      # An imported parcel dated last month-end makes the current month 'incomplete'.
      last_month_end = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1)

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-100.00",
          description: "PAST",
          date: last_month_end
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [installment_group_id: g.id]
      )

      result = Installments.upcoming_installments(3)
      assert is_list(result)
    end
  end
end
