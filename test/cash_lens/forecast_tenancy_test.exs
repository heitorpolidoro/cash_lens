defmodule CashLens.ForecastTenancyTest do
  @moduledoc """
  User B never reads, changes or projects user A's recurring items, history,
  accounts or card statements.

  Calls made for B run with the process pinned to A on purpose: row-level
  security would then let A's rows through, so what keeps them out of B's
  results is only the application-level `Ownership.scope/2` filter.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.CreditCardsFixtures
  import CashLens.ForecastFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem
  alias CashLens.Tenancy

  @today Date.utc_today()

  defp months_back(n) do
    month = @today.month - n
    {year, month} = if month <= 0, do: {@today.year - 1, month + 12}, else: {@today.year, month}
    Date.new!(year, month, 14)
  end

  setup do
    %{a: a, b: b} = cross_tenant()

    Tenancy.acting_as(a, fn ->
      cash = account_fixture(%{user: a, balance: "1000.00"})
      card = account_fixture(%{user: a, is_credit_card: true, closing_day: 5, due_day: 15})

      luz = category_fixture(%{user: a, type: "fixed", name: "Luz"})
      aluguel = category_fixture(%{user: a, type: "fixed", name: "Aluguel"})

      # Three recent months of "Luz": enough history for a detected recurrence.
      for n <- 0..2 do
        transaction_fixture(%{
          user: a,
          account_id: cash.id,
          category_id: luz.id,
          date: months_back(n),
          amount: "-334.16"
        })
      end

      # Variable spending and a recent ledger entry for the baseline/overdue paths.
      for n <- 1..2 do
        transaction_fixture(%{
          user: a,
          account_id: cash.id,
          date: Date.add(@today, -n),
          amount: "-60.00",
          description: "MERCADO #{n}"
        })
      end

      item = recurring_item_fixture(%{user: a, category_id: aluguel.id, amount: "-1500.00"})
      due = Forecast.next_occurrence_date(15, @today)

      statement_fixture(%{
        user: a,
        account: card,
        competencia: Date.beginning_of_month(due),
        due_date: due,
        total_a_pagar: Decimal.new("500.00")
      })

      %{a: a, b: b, cash: cash, card: card, luz: luz, aluguel: aluguel, item: item, due: due}
    end)
  end

  # B's calls run while the process is pinned to A.
  defp as_b(a, fun), do: Tenancy.acting_as(a, fun)

  defp snapshot(a) do
    Tenancy.acting_as(a, fn ->
      Repo.all(from r in RecurringItem, order_by: r.id)
    end)
  end

  test "the owner sees everything the checks below keep from B", ctx do
    %{a: a, due: due, item: item} = ctx

    Tenancy.acting_as(a, fn ->
      assert [%{id: id}] = Forecast.list_recurring_items(a)
      assert id == item.id
      assert [_] = Forecast.list_recurring_items_with_category(a)
      assert Forecast.get_recurring_item!(a, item.id).id == item.id
      assert {:ok, _} = Forecast.suggest_for_category(a, ctx.luz)
      assert [%{name: "Luz"}] = Forecast.list_categories_without_recurring_item(a)
      assert Forecast.variable_baseline_rate(a)

      projection = Forecast.project(a, 60)
      refute Decimal.equal?(projection.starting_balance, 0)
      assert Enum.any?(projection.occurrences, &(&1.item.id == item.id))

      assert Enum.any?(
               Forecast.card_occurrences(a, @today, Date.add(@today, 60)),
               &(&1.date == due and &1.origin == :boleto)
             )
    end)
  end

  describe "user B cannot read user A's forecast" do
    test "lists are empty", %{a: a, b: b} do
      as_b(a, fn ->
        assert Forecast.list_recurring_items(b) == []
        assert Forecast.list_recurring_items_with_category(b) == []
        assert Forecast.list_commitment_rows(b) == []
        assert Forecast.list_categories_without_recurring_item(b) == []
        assert Forecast.overdue_occurrences(b) == []
        assert Forecast.card_occurrences(b, @today, Date.add(@today, 60)) == []
        assert Forecast.commitment_occurrences(b, @today, Date.add(@today, 60)) == []
      end)
    end

    test "baseline, volatility and suggestions see none of A's history", %{
      a: a,
      b: b,
      luz: luz
    } do
      as_b(a, fn ->
        assert Forecast.variable_baseline_rate(b) == nil
        assert Forecast.monthly_volatility(b) == nil
        assert Forecast.suggest_for_category(b, luz) == :insufficient_history
      end)
    end

    test "the projection is a zero state", %{a: a, b: b} do
      as_b(a, fn ->
        projection = Forecast.project(b, 90)

        assert Decimal.equal?(projection.starting_balance, 0)
        assert projection.occurrences == []
        assert projection.zero_date == nil
        assert Forecast.upcoming_bills(projection).shown == []
      end)
    end

    test "lookups raise or return :not_found", %{a: a, b: b, item: item} do
      as_b(a, fn ->
        assert_raise Ecto.NoResultsError, fn -> Forecast.get_recurring_item!(b, item.id) end
        assert {:error, :not_found} = Forecast.fetch_recurring_item(b, item.id)
        assert {:error, :not_found} = Forecast.fetch_recurring_item(b, "not-a-uuid")
      end)
    end
  end

  describe "user B cannot change user A's forecast" do
    test "every write answers :not_found and leaves A's rows unchanged", %{a: a, b: b, item: item} do
      before = snapshot(a)

      as_b(a, fn ->
        assert {:error, :not_found} = Forecast.manual_update(b, item, %{"amount" => "-1.00"})
        assert {:error, :not_found} = Forecast.toggle_active(b, item)
        assert {:error, :not_found} = Forecast.set_as_salary(b, item)
        assert {:error, :not_found} = Forecast.unset_salary(b, item)
        assert {:error, :not_found} = Forecast.resync_item(b, item)
        assert {:error, :not_found} = Forecast.delete_recurring_item(b, item)
      end)

      assert snapshot(a) == before
    end

    test "sync_all and deactivate_superseded_items touch only B's rows", %{a: a, b: b} do
      before = snapshot(a)

      as_b(a, fn ->
        assert Forecast.sync_all(b) == %{created: 0, updated: 0, deactivated: 0}
        assert Forecast.deactivate_superseded_items(b) == []
      end)

      assert snapshot(a) == before
    end

    test "sync_all for the owner does write (the check above has teeth)", %{a: a, luz: luz} do
      Tenancy.acting_as(a, fn ->
        assert %{created: 1} = Forecast.sync_all(a)
        assert Enum.any?(Forecast.list_recurring_items(a), &(&1.category_id == luz.id))
      end)
    end

    test "set_as_salary clears the salary flag only among the user's own items", %{
      a: a,
      b: b,
      item: item
    } do
      Tenancy.acting_as(a, fn ->
        assert {:ok, %{is_salary: true}} = Forecast.set_as_salary(a, item)
      end)

      b_category = Tenancy.acting_as(b, fn -> category_fixture(%{user: b, type: "fixed"}) end)

      b_item =
        Tenancy.acting_as(b, fn ->
          recurring_item_fixture(%{user: b, category_id: b_category.id})
        end)

      Tenancy.acting_as(b, fn ->
        assert {:ok, %{is_salary: true}} = Forecast.set_as_salary(b, b_item)
      end)

      assert [%{is_salary: true}] = snapshot(a)
    end

    test "B cannot create an item on A's category", %{a: a, b: b, luz: luz} do
      before = snapshot(a)

      as_b(a, fn ->
        assert {:error, changeset} =
                 Forecast.create_recurring_item(b, %{
                   "category_id" => luz.id,
                   "label" => "stolen",
                   "day_of_month" => 3,
                   "amount" => "-10.00"
                 })

        assert %{category_id: ["does not exist"]} = errors_on(changeset)
        assert Forecast.list_recurring_items(b) == []
      end)

      assert snapshot(a) == before
    end

    test "creating ignores a user_id in the attrs and owns the row by the user", %{
      a: a,
      b: b
    } do
      b_category = Tenancy.acting_as(b, fn -> category_fixture(%{user: b, type: "fixed"}) end)

      Tenancy.acting_as(b, fn ->
        assert {:ok, item} =
                 Forecast.create_recurring_item(b, %{
                   "user_id" => a.id,
                   "category_id" => b_category.id,
                   "label" => "mine",
                   "day_of_month" => 3,
                   "amount" => "-10.00"
                 })

        assert item.user_id == b.id
      end)
    end
  end
end
