defmodule CashLens.ForecastTest do
  use CashLens.DataCase, async: false

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem

  import Ecto.Query, only: [from: 2]
  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures

  # Detection now requires a recent occurrence, so a fixed date drifts out of
  # range as the calendar moves. Every history fixture is anchored to today.
  defp history_date(n, day) do
    today = Date.utc_today()
    month = today.month - n
    {year, month} = if month <= 0, do: {today.year - 1, month + 12}, else: {today.year, month}
    Date.new!(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  describe "suggest_for_category/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "returns :insufficient_history with fewer than 2 occurrences" do
      category = category_fixture(%{type: "fixed"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-50.00"
      })

      assert Forecast.suggest_for_category(category) == :insufficient_history
    end

    test "suggests the median day and the most recent amount" do
      category = category_fixture(%{type: "fixed"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(2, 10),
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(1, 12),
        amount: "-52.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(0, 15),
        amount: "-55.00"
      })

      assert {:ok, %{"day_of_month" => 12, "amount" => amount}} =
               Forecast.suggest_for_category(category)

      assert Decimal.equal?(amount, "-55.00")
    end

    test "ignores transactions on credit card accounts" do
      category = category_fixture(%{type: "fixed"})
      cc_account = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: cc_account.id,
        category_id: category.id,
        date: ~D[2026-04-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: cc_account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      assert Forecast.suggest_for_category(category) == :insufficient_history
    end
  end

  describe "create_recurring_item/1" do
    test "creates with valid attrs" do
      category = category_fixture(%{type: "fixed"})

      assert {:ok, %RecurringItem{} = item} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: category.name,
                 day_of_month: 10,
                 amount: "-100.00"
               })

      assert item.day_of_month == 10
      assert Decimal.equal?(item.amount, "-100.00")
      assert item.active == true
      assert item.manually_edited == false
    end

    test "rejects day_of_month outside 1..31" do
      category = category_fixture(%{type: "fixed"})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "x",
                 day_of_month: 32,
                 amount: "-10.00"
               })

      assert "must be less than or equal to 31" in errors_on(changeset).day_of_month
    end

    test "rejects amount of zero" do
      category = category_fixture(%{type: "fixed"})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "x",
                 day_of_month: 10,
                 amount: "0"
               })

      assert "não pode ser zero" in errors_on(changeset).amount
    end

    test "rejects a second item for the same category" do
      category = category_fixture(%{type: "fixed"})
      recurring_item_fixture(%{category_id: category.id})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "dup",
                 day_of_month: 5,
                 amount: "-1.00"
               })

      assert "has already been taken" in errors_on(changeset).category_id
    end
  end

  describe "list_recurring_items/0 and get_recurring_item!/1" do
    test "lists items ordered by day_of_month" do
      recurring_item_fixture(%{day_of_month: 20})
      recurring_item_fixture(%{day_of_month: 5})

      assert [first, second] = Forecast.list_recurring_items()
      assert first.day_of_month == 5
      assert second.day_of_month == 20
    end

    test "get_recurring_item!/1 fetches by id" do
      item = recurring_item_fixture()
      assert Forecast.get_recurring_item!(item.id).id == item.id
    end
  end

  describe "detection requires a recent occurrence" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    defp three_months(category, account, newest_months_back) do
      for n <- newest_months_back..(newest_months_back + 2) do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: history_date(n, 10),
          amount: "-50.00"
        })
      end
    end

    test "a bill that stopped appearing is not a recurrence" do
      # Three occurrences four, five and six months back clears the minimum and
      # is still not recurring: it stopped.
      category = category_fixture(%{type: "fixed", name: "Parou"})
      account = account_fixture()
      three_months(category, account, 4)

      assert Forecast.suggest_for_category(category) == :no_recent_occurrence
    end

    test "last month counts, because this month may not be imported yet" do
      # The cut-off is the first of LAST month on purpose: on the first days of
      # a month nothing has been loaded yet, and measuring against the current
      # month would drop every account at once.
      category = category_fixture(%{type: "fixed", name: "Luz"})
      account = account_fixture()
      three_months(category, account, 1)

      assert {:ok, _} = Forecast.suggest_for_category(category)
    end

    test "two months back is already too old" do
      category = category_fixture(%{type: "fixed", name: "Antiga"})
      account = account_fixture()
      three_months(category, account, 2)

      assert Forecast.suggest_for_category(category) == :no_recent_occurrence
    end

    test "sync_all creates nothing for a bill that stopped" do
      category = category_fixture(%{type: "fixed", name: "Parou"})
      account = account_fixture()
      three_months(category, account, 4)

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
      assert Forecast.list_recurring_items() == []
    end

    test "sync_all switches off an item whose bill stopped arriving" do
      category = category_fixture(%{type: "fixed", name: "Streaming"})
      account = account_fixture()
      three_months(category, account, 4)

      item = recurring_item_fixture(%{category_id: category.id})

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 1}
      refute Forecast.get_recurring_item!(item.id).active
    end

    test "switching off is not deleting: the label and the edits survive" do
      # A recurrence that stops is usually a service that ended, but it is
      # sometimes a month nobody imported yet.
      category = category_fixture(%{type: "fixed", name: "Streaming"})
      account = account_fixture()
      three_months(category, account, 4)

      item = recurring_item_fixture(%{category_id: category.id, label: "Netflix"})

      Forecast.sync_all()

      reloaded = Forecast.get_recurring_item!(item.id)
      assert reloaded.label == "Netflix"
      assert Decimal.equal?(reloaded.amount, item.amount)
    end

    test "an item already switched off is not counted again" do
      category = category_fixture(%{type: "fixed", name: "Streaming"})
      account = account_fixture()
      three_months(category, account, 4)

      recurring_item_fixture(%{category_id: category.id, active: false})

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
    end

    test "a manually edited item is left on, like the rest of the sync leaves it" do
      # Its numbers are the person's, and so is the decision to switch it off.
      category = category_fixture(%{type: "fixed", name: "Streaming"})
      account = account_fixture()
      three_months(category, account, 4)

      item = recurring_item_fixture(%{category_id: category.id, manually_edited: true})

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
      assert Forecast.get_recurring_item!(item.id).active
    end

    test "an item that is still arriving is updated, not switched off" do
      category = category_fixture(%{type: "fixed", name: "Luz"})
      account = account_fixture()
      three_months(category, account, 0)

      item = recurring_item_fixture(%{category_id: category.id, day_of_month: 1})

      assert Forecast.sync_all() == %{created: 0, updated: 1, deactivated: 0}

      reloaded = Forecast.get_recurring_item!(item.id)
      assert reloaded.active
      assert reloaded.day_of_month == 10
    end

    test "resync says why it cannot, rather than reporting no history" do
      category = category_fixture(%{type: "fixed", name: "Parou"})
      account = account_fixture()
      three_months(category, account, 4)

      item = recurring_item_fixture(%{category_id: category.id})

      assert Forecast.resync_item(item) == {:error, :no_recent_occurrence}
    end
  end

  describe "the suggested day" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    defp on_days(category, account, days) do
      days
      |> Enum.with_index()
      |> Enum.each(fn {day, index} ->
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: history_date(index, day),
          amount: "-50.00"
        })
      end)
    end

    test "is the day the bill most often lands on" do
      # 14, 14, 20: the median would say 14 too, so the day that separates them
      # is 20 -- here the most frequent wins outright.
      category = category_fixture(%{type: "fixed", name: "Luz"})
      account = account_fixture()
      on_days(category, account, [20, 14, 14])

      assert {:ok, %{"day_of_month" => 14}} = Forecast.suggest_for_category(category)
    end

    test "a repeated late day beats a single early one" do
      category = category_fixture(%{type: "fixed", name: "Seguro"})
      account = account_fixture()
      on_days(category, account, [25, 25, 3])

      assert {:ok, %{"day_of_month" => 25}} = Forecast.suggest_for_category(category)
    end

    test "the most frequent day wins even when it sits at one end" do
      # Five months: the 28th twice, then three scattered days. The median of
      # them is the 15th, which is a day this bill never once landed on.
      category = category_fixture(%{type: "fixed", name: "Seguro"})
      account = account_fixture()
      on_days(category, account, [28, 28, 3, 10, 15])

      assert {:ok, %{"day_of_month" => 28}} = Forecast.suggest_for_category(category)
    end

    test "falls back to the median when every day is distinct" do
      # Bills shift around weekends, so with a handful of samples there is often
      # no most frequent day at all.
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()
      on_days(category, account, [18, 15, 12])

      assert {:ok, %{"day_of_month" => 15}} = Forecast.suggest_for_category(category)
    end
  end

  describe "sync_all/0" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "creates an item for a fixed category with enough history" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(1, 10),
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(0, 10),
        amount: "-52.00"
      })

      assert Forecast.sync_all() == %{created: 1, updated: 0, deactivated: 0}
      assert [item] = Forecast.list_recurring_items()
      assert item.label == "Água"
      assert item.day_of_month == 10
    end

    test "does not create an item for a category with insufficient history" do
      category_fixture(%{type: "fixed", name: "Sem histórico"})

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
      assert Forecast.list_recurring_items() == []
    end

    test "ignores variable categories" do
      category_fixture(%{type: "variable", name: "Mercado"})

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
    end

    test "updates an existing non-manually-edited item, leaves manually-edited ones alone" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(1, 10),
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(0, 15),
        amount: "-60.00"
      })

      auto_item =
        recurring_item_fixture(%{category_id: category.id, day_of_month: 1, amount: "-1.00"})

      assert Forecast.sync_all() == %{created: 0, updated: 1, deactivated: 0}

      reloaded = Forecast.get_recurring_item!(auto_item.id)
      assert reloaded.day_of_month == 10
      assert Decimal.equal?(reloaded.amount, "-60.00")
    end

    test "leaves a manually_edited item untouched" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(1, 10),
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(0, 15),
        amount: "-60.00"
      })

      edited_item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}

      reloaded = Forecast.get_recurring_item!(edited_item.id)
      assert reloaded.day_of_month == 1
      assert Decimal.equal?(reloaded.amount, "-1.00")
    end

    test "never creates a recurring_item for a credit-card category" do
      regular_account = account_fixture()

      {:ok, category} =
        CashLens.Categories.create_category(%{
          name: "Cartão de Crédito",
          slug: "cartao-de-credito",
          type: "fixed"
        })

      for i <- 1..3 do
        transaction_fixture(%{
          account_id: regular_account.id,
          category_id: category.id,
          amount: Decimal.new("-100.00"),
          date: Date.add(Date.utc_today(), -30 * i)
        })
      end

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
      assert Forecast.list_recurring_items() == []
    end
  end

  describe "resync_item/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "forces an update and resets manually_edited to false" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(1, 10),
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(0, 20),
        amount: "-99.00"
      })

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert {:ok, updated} = Forecast.resync_item(item)
      assert updated.day_of_month == 10
      assert Decimal.equal?(updated.amount, "-99.00")
      assert updated.manually_edited == false
    end

    test "returns an error when there isn't enough history" do
      item = recurring_item_fixture()
      assert Forecast.resync_item(item) == {:error, :insufficient_history}
    end
  end

  describe "manual_update/2" do
    test "updates the fields and marks manually_edited" do
      item = recurring_item_fixture(%{day_of_month: 5, amount: "-10.00"})

      assert {:ok, updated} =
               Forecast.manual_update(item, %{"day_of_month" => "20", "amount" => "-15.00"})

      assert updated.day_of_month == 20
      assert Decimal.equal?(updated.amount, "-15.00")
      assert updated.manually_edited == true
    end

    test "returns an error changeset for an invalid day" do
      item = recurring_item_fixture()
      assert {:error, changeset} = Forecast.manual_update(item, %{"day_of_month" => "40"})
      assert "must be less than or equal to 31" in errors_on(changeset).day_of_month
    end
  end

  describe "toggle_active/1" do
    test "flips active from true to false and back" do
      item = recurring_item_fixture(%{active: true})

      assert {:ok, %{active: false} = toggled} = Forecast.toggle_active(item)
      assert {:ok, %{active: true}} = Forecast.toggle_active(toggled)
    end
  end

  describe "project/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures
    import CashLens.CreditCardsFixtures

    setup do
      account = account_fixture(%{balance: "1000.00"})
      cc_account = account_fixture(%{balance: "5000.00", is_credit_card: true})
      %{account: account, cc_account: cc_account}
    end

    test "starting_balance excludes credit card and closed accounts", %{
      account: _account,
      cc_account: cc_account
    } do
      closed = account_fixture(%{balance: "2000.00", is_closed: true})
      projection = Forecast.project()

      assert Decimal.equal?(projection.starting_balance, "1000.00")
      refute cc_account.is_credit_card == false
      assert closed.is_closed
    end

    test "includes card occurrences merged with recurring items" do
      card = account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10})
      due_date = Forecast.next_occurrence_date(10, Date.utc_today())

      s =
        statement_fixture(%{
          account: card,
          due_date: due_date,
          competencia: Date.beginning_of_month(due_date),
          total_a_pagar: Decimal.new("800.00")
        })

      projection = Forecast.project(60)

      assert Enum.any?(projection.occurrences, fn occ ->
               occ.origin == :boleto and occ.date == s.due_date and
                 Decimal.equal?(occ.item.amount, Decimal.new("-800.00"))
             end)

      # Merged list stays sorted by date and every occurrence got a balance_after.
      dates = Enum.map(projection.occurrences, & &1.date)
      assert dates == Enum.sort(dates, Date)
      assert Enum.all?(projection.occurrences, &(&1.balance_after != nil))
    end

    test "inactive items don't appear in the projection" do
      recurring_item_fixture(%{day_of_month: 1, amount: "-2000.00", active: false})
      projection = Forecast.project()
      assert projection.occurrences == []
      assert projection.zero_date == nil
    end

    test "finds the date the balance goes negative", %{account: _account} do
      today = Date.utc_today()
      future_day = today.day

      recurring_item_fixture(%{day_of_month: future_day, amount: "-2000.00"})

      projection = Forecast.project()

      assert projection.zero_date == today
      assert %{date: ^today, balance_after: balance} = hd(projection.occurrences)
      assert Decimal.equal?(balance, "-1000.00")
    end

    test "zero_date is nil when the balance never reaches zero" do
      recurring_item_fixture(%{day_of_month: 15, amount: "-1.00"})
      projection = Forecast.project()
      assert projection.zero_date == nil
    end

    test "landing exactly on zero counts as the zero date" do
      today = Date.utc_today()

      # The setup's starting balance is 1000.00, so this lands the running
      # balance on exactly 0.00 -- which is running out of money, not one cent
      # short of it.
      recurring_item_fixture(%{day_of_month: today.day, amount: "-1000.00"})

      projection = Forecast.project()

      assert %{date: ^today, balance_after: balance} = hd(projection.occurrences)
      assert Decimal.equal?(balance, "0.00")
      assert projection.zero_date == today
    end
  end

  describe "daily_balances/2" do
    defp projection_with(occurrence_offsets, starting_balance \\ "100.00") do
      today = Date.utc_today()

      %{
        starting_balance: Decimal.new(starting_balance),
        occurrences:
          Enum.map(occurrence_offsets, fn {offset, balance_after} ->
            %{date: Date.add(today, offset), item: nil, balance_after: Decimal.new(balance_after)}
          end),
        zero_date: nil
      }
    end

    test "returns one point per day, today through the horizon inclusive" do
      points = Forecast.daily_balances(projection_with([]), 365)
      today = Date.utc_today()

      assert length(points) == 366
      assert hd(points).date == today
      assert List.last(points).date == Date.add(today, 365)
      assert Enum.map(points, & &1.date) == Enum.sort(Enum.map(points, & &1.date), Date)
    end

    test "holds the balance flat on days when nothing settles" do
      points = Forecast.daily_balances(projection_with([{5, "40.00"}]), 10)

      # Days 0..4 keep the starting balance, days 5..10 keep the new one.
      for %{date: date, balance: balance} <- points do
        offset = Date.diff(date, Date.utc_today())
        expected = if offset < 5, do: "100.00", else: "40.00"

        assert Decimal.equal?(balance, expected),
               "day #{offset} should be #{expected}, got #{balance}"
      end
    end

    test "a day with several occurrences carries the balance after the last one" do
      points = Forecast.daily_balances(projection_with([{3, "70.00"}, {3, "25.00"}]), 5)
      day_three = Enum.find(points, &(Date.diff(&1.date, Date.utc_today()) == 3))

      assert Decimal.equal?(day_three.balance, "25.00")
    end

    test "every point agrees with balance_on/2 for the same date" do
      # balance_on/2 is tested independently above, so this is a cross-check of
      # two different traversals rather than a restatement of one of them.
      projection = projection_with([{2, "80.00"}, {7, "-15.00"}, {9, "120.00"}])
      points = Forecast.daily_balances(projection, 12)

      for %{date: date, balance: balance} <- points do
        assert Decimal.equal?(balance, Forecast.balance_on(projection, date)),
               "disagreement on #{date}"
      end
    end

    test "carries the starting balance throughout when nothing settles at all" do
      points = Forecast.daily_balances(projection_with([], "250.00"), 30)

      assert Enum.all?(points, &Decimal.equal?(&1.balance, "250.00"))
    end
  end

  describe "balance_on/2" do
    test "returns starting_balance when the date is before any occurrence" do
      projection = %{
        starting_balance: Decimal.new("100.00"),
        occurrences: [
          %{date: ~D[2026-07-01], item: nil, balance_after: Decimal.new("50.00")}
        ],
        zero_date: nil
      }

      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-06-01]), "100.00")
    end

    test "returns the cumulative balance as of the given date" do
      projection = %{
        starting_balance: Decimal.new("100.00"),
        occurrences: [
          %{date: ~D[2026-07-01], item: nil, balance_after: Decimal.new("50.00")},
          %{date: ~D[2026-07-10], item: nil, balance_after: Decimal.new("80.00")}
        ],
        zero_date: nil
      }

      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-07-05]), "50.00")
      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-07-10]), "80.00")
      assert Decimal.equal?(Forecast.balance_on(projection, ~D[2026-12-31]), "80.00")
    end
  end

  describe "next_income_date/1" do
    test "returns the date of the first occurrence with is_salary: true" do
      projection = %{
        starting_balance: Decimal.new("0"),
        occurrences: [
          %{
            date: ~D[2026-07-01],
            item: %{amount: Decimal.new("-50.00"), is_salary: false},
            balance_after: nil
          },
          %{
            date: ~D[2026-07-05],
            item: %{amount: Decimal.new("3000.00"), is_salary: true},
            balance_after: nil
          }
        ],
        zero_date: nil
      }

      assert Forecast.next_income_date(projection) == ~D[2026-07-05]
    end

    test "falls back to today + 30 days when no is_salary item exists" do
      projection = %{starting_balance: Decimal.new("0"), occurrences: [], zero_date: nil}
      assert Forecast.next_income_date(projection) == Date.add(Date.utc_today(), 30)
    end
  end

  describe "card_occurrences/2" do
    setup do
      card =
        CashLens.AccountsFixtures.account_fixture(%{
          is_credit_card: true,
          closing_day: 3,
          due_day: 10
        })

      %{card: card}
    end

    test "real unpaid boleto due in range uses its exact total and date", %{card: card} do
      s =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: ~D[2026-08-10],
          competencia: ~D[2026-08-01],
          total_a_pagar: Decimal.new("1500.00")
        })

      [occ] = CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31])
      assert occ.date == s.due_date
      assert Decimal.equal?(occ.item.amount, Decimal.new("-1500.00"))
      assert occ.origin == :boleto
      assert occ.item.id == card.id
    end

    test "a bill with nothing to pay takes nothing out, and never puts anything in", %{card: card} do
      # A negative total is a credit on the card -- a refund, an overpayment. It
      # settles against the next bill, not against the current account, so a
      # projection that reads it as money arriving invents cash no bank will
      # move: the real Amazon bill of out/2026, at -226,32, was projected as a
      # deposit of 226,32 sitting beside the salary.
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: ~D[2026-08-10],
        competencia: ~D[2026-08-01],
        total_a_pagar: Decimal.new("-226.32")
      })

      [occ] = CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31])
      assert occ.origin == :boleto
      assert Decimal.equal?(occ.item.amount, Decimal.new("0"))
      refute Decimal.positive?(occ.item.amount)
    end

    test "a bill without a total adds up its own lines, and still never pays in", %{card: card} do
      # The fallback for a bill whose total was never read: it sums the lines.
      # A statement holding only a refund sums positive, and the same rule has
      # to hold there -- the money the card owes the account is zero, not a
      # deposit.
      statement =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: ~D[2026-08-10],
          competencia: ~D[2026-08-01],
          total_a_pagar: nil
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        import_batch_id: statement.id,
        date: ~D[2026-07-20],
        amount: Decimal.new("80.00")
      })

      [occ] = CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31])
      assert occ.origin == :boleto
      assert Decimal.equal?(occ.item.amount, Decimal.new("0"))
    end

    test "a credit bill does not drag the estimate below the card's real spending", %{card: card} do
      # Same rule inside the average: a month that billed nothing is a month of
      # zero, not a month of negative spending to be subtracted from the others.
      for {offset, total} <- [{-30, "1200.00"}, {-60, "-300.00"}, {-90, "900.00"}] do
        due = Date.add(Date.utc_today(), offset)

        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: due,
          competencia: Date.beginning_of_month(due),
          total_a_pagar: Decimal.new(total)
        })
      end

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      [occ] =
        CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert occ.origin == :estimado
      # (1200 + 0 + 900) / 3 = 700. Counting the credit as -300 gives 600.
      assert Decimal.equal?(occ.item.amount, Decimal.new("-700.00"))
    end

    test "paid boleto produces no occurrence for its month", %{card: card} do
      payment =
        CashLens.TransactionsFixtures.transaction_fixture(%{
          account_id: CashLens.AccountsFixtures.account_fixture().id,
          amount: Decimal.new("1500.00")
        })

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: ~D[2026-08-10],
        competencia: ~D[2026-08-01],
        total_a_pagar: Decimal.new("1500.00"),
        payment_transaction_id: payment.id
      })

      assert CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31]) == []
    end

    test "no boleto for the month estimates from the recent boleto plus that month's installments",
         %{
           card: card
         } do
      # Recent boleto (within 6 months): total 2000, with a 500 installment of its own.
      recent =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: Date.add(Date.utc_today(), -30),
          competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -30)),
          total_a_pagar: Decimal.new("2000.00")
        })

      {:ok, recent_group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "RECENT_PARCEL",
          installments: 2,
          start_date: Date.beginning_of_month(recent.due_date),
          total_amount: Decimal.new("1000.00")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        installment_group_id: recent_group.id,
        installment_number: 1,
        date: recent.due_date,
        amount: Decimal.new("-500.00")
      })

      # Future month has its own different installment of 200.
      future_month = Date.add(Date.utc_today(), 60)
      future_first = Date.beginning_of_month(future_month)

      {:ok, future_group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "FUTURE_PARCEL",
          installments: 2,
          start_date: future_first,
          total_amount: Decimal.new("400.00")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        installment_group_id: future_group.id,
        installment_number: 1,
        date: future_first,
        amount: Decimal.new("-200.00")
      })

      occurrences =
        CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert [occ] = occurrences
      assert occ.origin == :estimado
      # variable = -2000 + 500 = -1500. The month schedules 200, but this card
      # typically carries 500 of parcels, so the usual load is what gets
      # charged: -1500 - 500 = -2000.
      assert Decimal.equal?(occ.item.amount, Decimal.new("-2000.00"))
      assert Decimal.equal?(occ.installment_total, Decimal.new("500.00"))

      # The 300 the schedule does not account for is named as a trend, never
      # attributed to FUTURE_PARCEL, which bills its own 200 and no more.
      assert [scheduled, trend] = occ.installment_groups
      assert scheduled.description == "FUTURE_PARCEL"
      assert Decimal.equal?(scheduled.parcel_value, Decimal.new("200.00"))
      assert trend.description == "Novas parcelas (tendência)"
      assert Decimal.equal?(trend.parcel_value, Decimal.new("300.00"))
    end

    test "estimates from the average of the card's recent bills, not its last one", %{card: card} do
      # A single bill is a sample of one, and the amount swings: whichever month
      # happened to be last drove the whole twelve-month projection, so a light
      # month projected a light year.
      for {offset, total} <- [{-30, "1200.00"}, {-60, "800.00"}, {-90, "1000.00"}] do
        due = Date.add(Date.utc_today(), offset)

        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: due,
          competencia: Date.beginning_of_month(due),
          total_a_pagar: Decimal.new(total)
        })
      end

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      occurrences =
        CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert [occ] = occurrences
      assert occ.origin == :estimado
      # (1200 + 800 + 1000) / 3 = 1000, not the 1200 of the most recent bill.
      assert Decimal.equal?(occ.item.amount, Decimal.new("-1000.00"))
    end

    test "a finished plan keeps its level as a trend, without billing a parcel it does not have",
         %{
           card: card
         } do
      # Two bills of 2000, each carrying one 500,00 parcel of a plan that ends
      # before the projected month. The schedule says the projected month owes
      # nothing, but twelve months of history say a card that has been carrying
      # 500,00 of parcels goes on carrying it -- a plan that ends is replaced by
      # a new purchase. So the level is held, as a trend on its own line, and
      # ENDED_PARCEL is never listed as billing a parcel after its last one.
      older_due = Date.add(Date.utc_today(), -60)
      older_competencia = Date.beginning_of_month(older_due)
      newer_due = Date.add(Date.utc_today(), -30)

      for due <- [newer_due, older_due] do
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: due,
          competencia: Date.beginning_of_month(due),
          total_a_pagar: Decimal.new("2000.00")
        })
      end

      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "ENDED_PARCEL",
          installments: 2,
          start_date: older_competencia,
          total_amount: Decimal.new("1000.00")
        })

      for {offset, date} <- [{1, older_competencia}, {2, Date.beginning_of_month(newer_due)}] do
        CashLens.TransactionsFixtures.transaction_fixture(%{
          account_id: card.id,
          installment_group_id: group.id,
          installment_number: offset,
          date: date,
          amount: Decimal.new("-500.00")
        })
      end

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      occurrences =
        CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert [occ] = occurrences
      assert Decimal.equal?(occ.item.amount, Decimal.new("-2000.00"))

      assert [trend] = occ.installment_groups
      assert trend.description == "Novas parcelas (tendência)"
      assert trend.parcel_number == nil
      assert Decimal.equal?(trend.parcel_value, Decimal.new("500.00"))
      refute Enum.any?(occ.installment_groups, &(&1.description == "ENDED_PARCEL"))
    end

    test "the usual parcel load is a floor, not a ceiling: a heavy month is charged in full",
         %{card: card} do
      # The floor holds a month UP to the card's usual load. It must never pull a
      # month DOWN to it: a month that really does schedule more parcels than
      # usual is the month most worth seeing, and averaging it away would hide
      # exactly the spike the ruler exists to warn about.
      due = Date.add(Date.utc_today(), -30)
      competencia = Date.beginning_of_month(due)

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: due,
        competencia: competencia,
        total_a_pagar: Decimal.new("2000.00")
      })

      {:ok, past_group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "USUAL_PARCEL",
          installments: 2,
          start_date: competencia,
          total_amount: Decimal.new("600.00")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        installment_group_id: past_group.id,
        installment_number: 1,
        date: competencia,
        amount: Decimal.new("-300.00")
      })

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      {:ok, heavy_group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "HEAVY_PARCEL",
          installments: 2,
          start_date: future_first,
          total_amount: Decimal.new("3000.00")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        installment_group_id: heavy_group.id,
        installment_number: 1,
        date: future_first,
        amount: Decimal.new("-1500.00")
      })

      assert [occ] =
               CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      # variable = -2000 + 300 = -1700 ; the month's own 1500 beats the 300
      # typical load, so it is charged whole: -1700 - 1500 = -3200.
      assert Decimal.equal?(occ.item.amount, Decimal.new("-3200.00"))
      assert Decimal.equal?(occ.installment_total, Decimal.new("1500.00"))

      # And nothing is disclosed as a trend, because the schedule covers the bill.
      assert [disclosed] = occ.installment_groups
      assert disclosed.description == "HEAVY_PARCEL"
    end

    test "a card with one bill estimates from it, unchanged", %{card: card} do
      # The average degrades gracefully: a new card must still be projected.
      due = Date.add(Date.utc_today(), -30)

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: due,
        competencia: Date.beginning_of_month(due),
        total_a_pagar: Decimal.new("777.00")
      })

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      assert [occ] =
               CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert Decimal.equal?(occ.item.amount, Decimal.new("-777.00"))
    end

    test "no recent boleto within history window yields no occurrences", %{card: card} do
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: Date.add(Date.utc_today(), -400),
        competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -400)),
        total_a_pagar: Decimal.new("2000.00")
      })

      future_month = Date.add(Date.utc_today(), 60)

      assert CashLens.Forecast.card_occurrences(future_month, Date.end_of_month(future_month)) ==
               []
    end

    test "account without a configured cycle yields no occurrences" do
      CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      today = Date.utc_today()
      assert CashLens.Forecast.card_occurrences(today, Date.add(today, 60)) == []
    end

    test "estimate subtracts the recent boleto's installment using its competencia month, not its due_date month",
         %{card: card} do
      recent_due_date = Date.add(Date.utc_today(), -30)
      due_month = Date.beginning_of_month(recent_due_date)
      competencia_month = due_month |> Date.add(-32) |> Date.beginning_of_month()

      recent =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: recent_due_date,
          competencia: competencia_month,
          total_a_pagar: Decimal.new("2000.00")
        })

      {:ok, competencia_group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "COMPETENCIA_PARCEL",
          installments: 2,
          start_date: competencia_month,
          total_amount: Decimal.new("1000.00")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        installment_group_id: competencia_group.id,
        installment_number: 1,
        date: competencia_month,
        amount: Decimal.new("-500.00")
      })

      # Sanity: due_date and competencia really are in different (non-adjacent) months.
      refute Date.beginning_of_month(recent.due_date) == recent.competencia

      future_month = Date.add(Date.utc_today(), 60)
      future_first = Date.beginning_of_month(future_month)

      # The projected month schedules MORE than the card typically carries, so
      # `max(scheduled, typical)` resolves to the schedule. That is the branch
      # where the competência keying is still visible in the amount: when the
      # typical load wins instead, it cancels against the variable part it was
      # subtracted from, and both keyings would give the same number.
      {:ok, heavy_group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "HEAVY_PARCEL",
          installments: 2,
          start_date: future_first,
          total_amount: Decimal.new("1600.00")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        installment_group_id: heavy_group.id,
        installment_number: 1,
        date: future_first,
        amount: Decimal.new("-800.00")
      })

      occurrences =
        CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert [occ] = occurrences
      assert occ.origin == :estimado
      # If keyed by competencia (correct): variable = -2000 + 500 = -1500, and the
      # month's 800 schedule outweighs the 500 typical load, giving -2300.00.
      # If keyed by due_date's month (the bug): the installment lands outside that
      # month, so variable = -2000 and typical = 0, giving -2800.00 instead.
      assert Decimal.equal?(occ.item.amount, Decimal.new("-2300.00"))
    end

    test "two statements due in the same month do not crash and resolve deterministically", %{
      card: card
    } do
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: ~D[2026-08-05],
        competencia: ~D[2026-07-01],
        total_a_pagar: Decimal.new("100.00")
      })

      s2 =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: ~D[2026-08-20],
          competencia: ~D[2026-08-01],
          total_a_pagar: Decimal.new("300.00")
        })

      assert [occ] = CashLens.Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31])
      assert occ.date == s2.due_date
      assert Decimal.equal?(occ.item.amount, Decimal.new("-300.00"))
    end
  end

  describe "variable spending baseline" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    # The projection's three event sources -- recurring items, card bills and
    # off-card commitments -- model only money the user has already told the
    # system about. Everything else leaving a cash account (groceries on debit,
    # a Pix, fuel) was invisible, which made every projection structurally
    # optimistic: the real months ran negative while the forecast climbed.
    setup do
      account = account_fixture(%{balance: "1000.00"})
      variable = category_fixture(%{type: "variable", name: "Mercado livre de verdade"})
      %{account: account, variable: variable}
    end

    defp spend(account, category, date, amount) do
      transaction_fixture(%{
        account_id: account.id,
        category_id: category && category.id,
        date: date,
        amount: amount
      })
    end

    test "averages variable outflows over the window as a daily rate", %{
      account: account,
      variable: variable
    } do
      # 180 days in the window, so 1800,00 of spending is exactly -10,00/day.
      spend(account, variable, Date.add(Date.utc_today(), -10), "-1000.00")
      spend(account, variable, Date.add(Date.utc_today(), -100), "-800.00")

      rate = Forecast.variable_baseline_rate()

      assert Decimal.equal?(rate.daily, Decimal.new("-10.00"))
      assert Decimal.equal?(rate.monthly, Decimal.new("-300.00"))
      assert rate.months == 6
    end

    test "leaves out parcels already belonging to a commitment", %{
      account: account,
      variable: variable
    } do
      spend(account, variable, Date.add(Date.utc_today(), -10), "-1000.00")
      spend(account, variable, Date.add(Date.utc_today(), -100), "-800.00")

      # A financing's parcel sits in a variable category, so nothing but its
      # group membership keeps it out of the average — and it is already
      # projected on its own due date by commitment_occurrences/2.
      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "FINANCIAMENTO",
          commitment_type: "financing",
          installments: 60,
          start_date: Date.add(Date.utc_today(), -400),
          total_amount: "60000.00"
        })

      parcela = spend(account, variable, Date.add(Date.utc_today(), -20), "-3000.00")

      CashLens.Repo.update_all(
        from(t in CashLens.Transactions.Transaction, where: t.id == ^parcela.id),
        set: [installment_group_id: group.id, installment_number: 1]
      )

      # Still -10,00/day: the 3.000,00 parcel is not averaged in.
      assert Decimal.equal?(Forecast.variable_baseline_rate().daily, Decimal.new("-10.00"))
    end

    test "carries the arithmetic behind the rate, not just its result", %{
      account: account,
      variable: variable
    } do
      # The screen shows the division. A balance moved by a number nobody can
      # derive is worse than no number.
      spend(account, variable, Date.add(Date.utc_today(), -10), "-1800.00")

      rate = Forecast.variable_baseline_rate()

      assert Decimal.equal?(rate.total, Decimal.new("-1800.00"))
      assert rate.days == 180
      assert rate.since == Date.add(Date.utc_today(), -180)
      # The window stops yesterday: today's spending is already in the balance.
      assert rate.until == Date.add(Date.utc_today(), -1)
      # ... and the parts really do produce the whole.
      assert Decimal.equal?(Decimal.div(rate.total, rate.days) |> Decimal.round(2), rate.daily)
    end

    test "returns nil when the window holds no variable spending" do
      refute Forecast.variable_baseline_rate()
    end

    test "an uncategorized outflow counts -- unfiled money is still gone", %{account: account} do
      spend(account, nil, Date.add(Date.utc_today(), -5), "-1800.00")

      assert Decimal.equal?(Forecast.variable_baseline_rate().daily, Decimal.new("-10.00"))
    end

    test "ignores what the projection already models, and what never left", %{
      account: account,
      variable: variable
    } do
      fixed = category_fixture(%{type: "fixed", name: "Aluguel"})
      card_category = category_fixture(%{slug: "cartao-de-credito-ourocard", name: "Ourocard"})
      card_account = account_fixture(%{is_credit_card: true})

      # Already a RecurringItem.
      spend(account, fixed, Date.add(Date.utc_today(), -20), "-5000.00")
      # Already a card_occurrences/2 bill.
      spend(account, card_category, Date.add(Date.utc_today(), -20), "-5000.00")
      # A purchase on the card itself, not money leaving a cash account.
      spend(card_account, variable, Date.add(Date.utc_today(), -20), "-5000.00")
      # Income, not spending.
      spend(account, variable, Date.add(Date.utc_today(), -20), "5000.00")
      # Outside the window.
      spend(account, variable, Date.add(Date.utc_today(), -400), "-5000.00")

      refute Forecast.variable_baseline_rate()
    end

    test "a transfer between the user's own accounts is not spending", %{
      account: account,
      variable: variable
    } do
      tx = spend(account, variable, Date.add(Date.utc_today(), -20), "-1800.00")
      assert Decimal.equal?(Forecast.variable_baseline_rate().daily, Decimal.new("-10.00"))

      {:ok, _} =
        CashLens.Transactions.update_transaction(tx, %{transfer_key: Ecto.UUID.generate()})

      refute Forecast.variable_baseline_rate()
    end

    test "project/1 charges the rate once per day, starting tomorrow", %{
      account: account,
      variable: variable
    } do
      spend(account, variable, Date.add(Date.utc_today(), -10), "-1800.00")

      projection = Forecast.project(10)
      baseline = Enum.filter(projection.occurrences, & &1[:baseline])

      # Today's variable spending is already inside the starting balance, so
      # charging the average on top of it would count the same day twice.
      assert length(baseline) == 10
      refute Enum.any?(baseline, &(&1.date == Date.utc_today()))
      assert Enum.min_by(baseline, & &1.date, Date).date == Date.add(Date.utc_today(), 1)

      # 10 days at -10,00 below wherever the balance starts. Asserted as a delta
      # because the history that sets the rate is the same history that moved
      # the balance -- pinning an absolute would test the fixture, not the rate.
      assert Decimal.equal?(
               Decimal.sub(Forecast.final_balance(projection), projection.starting_balance),
               Decimal.new("-100.00")
             )
    end

    test "the baseline can be what brings the balance to zero", %{
      account: account,
      variable: variable
    } do
      spend(account, variable, Date.add(Date.utc_today(), -10), "-18000.00")
      # Income is not variable spending, so this lifts the balance back to
      # 1000,00 without touching the -100,00/day rate the outflow above sets.
      spend(account, variable, Date.add(Date.utc_today(), -10), "18000.00")

      projection = Forecast.project(30)

      assert Decimal.equal?(projection.starting_balance, Decimal.new("1000.00"))
      assert projection.zero_date == Date.add(Date.utc_today(), 10)
    end

    test "ruler_occurrences/2 hides the baseline but keeps its drag in the balances", %{
      account: account,
      variable: variable
    } do
      spend(account, variable, Date.add(Date.utc_today(), -10), "-1800.00")

      item =
        recurring_item_fixture(%{
          day_of_month: Date.add(Date.utc_today(), 5).day,
          amount: "-100.00"
        })

      projection = Forecast.project(10)
      ruler = Forecast.ruler_occurrences(projection, 10)

      # The average is not an event: there is no bill to go look at behind any
      # one of 365 identical cards, and listing them buries the real ones.
      assert Enum.all?(ruler, &is_nil(&1[:baseline]))
      refute Enum.empty?(ruler)
      assert Enum.any?(Forecast.occurrences_within(projection, 10), & &1[:baseline])

      # ... but the balance shown next to the recurring item still accounts for
      # the days of average spending that preceded it.
      occ = Enum.find(ruler, &(&1.item.id == item.id))
      refute is_nil(occ)

      # Four preceding days of average spending (-40,00) plus the item itself
      # (-100,00), measured from the starting balance.
      assert Decimal.equal?(
               Decimal.sub(occ.balance_after, projection.starting_balance),
               Decimal.new("-140.00")
             )
    end
  end

  describe "list_categories_without_recurring_item/0" do
    test "returns only categories with no recurring item, excluding credit-card ones" do
      free = category_fixture(%{name: "Academia", type: "fixed"})
      taken = category_fixture(%{name: "Aluguel", type: "fixed"})
      card = category_fixture(%{name: "Cartao de Credito", type: "fixed"})
      assert card.slug == "cartao-de-credito"

      recurring_item_fixture(%{category_id: taken.id})

      names = Enum.map(Forecast.list_categories_without_recurring_item(), & &1.name)

      assert "Academia" in names
      refute "Aluguel" in names
      refute "Cartao de Credito" in names

      recurring_item_fixture(%{category_id: free.id, label: "Academia"})

      refute "Academia" in Enum.map(Forecast.list_categories_without_recurring_item(), & &1.name)
    end
  end

  describe "projection slices" do
    import CashLens.AccountsFixtures

    setup do
      account_fixture(%{balance: "1000.00"})
      :ok
    end

    test "occurrences_within/2 keeps only the occurrences settling inside the window" do
      near = Date.add(Date.utc_today(), 5)
      far = Date.add(Date.utc_today(), 45)

      recurring_item_fixture(%{day_of_month: near.day, amount: "-10.00", label: "perto"})
      recurring_item_fixture(%{day_of_month: far.day, amount: "-20.00", label: "longe"})

      projection = Forecast.project(90)
      within = Forecast.occurrences_within(projection, 30)
      limit = Date.add(Date.utc_today(), 30)

      assert Enum.all?(within, &(Date.compare(&1.date, limit) != :gt))
      assert length(within) < length(projection.occurrences)
    end

    test "minimum_point/2 ignores occurrences outside the window" do
      inside = Date.add(Date.utc_today(), 3)
      outside = Date.add(Date.utc_today(), 60)

      recurring_item_fixture(%{day_of_month: inside.day, amount: "-100.00", label: "dentro"})
      recurring_item_fixture(%{day_of_month: outside.day, amount: "-900.00", label: "fora"})

      projection = Forecast.project(90)
      minimum = Forecast.minimum_point(projection, 30)

      assert Date.compare(minimum.date, Date.add(Date.utc_today(), 30)) != :gt

      assert Decimal.compare(
               minimum.balance_after,
               Forecast.minimum_point(projection, 90).balance_after
             ) ==
               :gt
    end

    test "minimum_point/2 is nil when nothing settles inside the window" do
      assert Forecast.minimum_point(Forecast.project(90), 30) == nil
    end

    test "final_balance/1 reads the balance after the last occurrence" do
      recurring_item_fixture(%{day_of_month: 10, amount: "-10.00"})
      projection = Forecast.project(365)

      assert Decimal.equal?(
               Forecast.final_balance(projection),
               List.last(projection.occurrences).balance_after
             )
    end

    test "final_balance/1 falls back to the starting balance without occurrences" do
      projection = Forecast.project(365)
      assert Decimal.equal?(Forecast.final_balance(projection), projection.starting_balance)
    end

    test "projected_change_percent/1 is the signed whole-percent change, nil at zero balance" do
      recurring_item_fixture(%{day_of_month: 10, amount: "-50.00"})
      projection = Forecast.project(365)

      expected =
        Forecast.final_balance(projection)
        |> Decimal.sub(projection.starting_balance)
        |> Decimal.div(projection.starting_balance)
        |> Decimal.mult(100)
        |> Decimal.round(0)

      assert Decimal.equal?(Forecast.projected_change_percent(projection), expected)

      assert Forecast.projected_change_percent(%{
               projection
               | starting_balance: Decimal.new("0")
             }) == nil
    end
  end

  describe "card occurrence installment disclosure" do
    import CashLens.AccountsFixtures
    import CashLens.CreditCardsFixtures
    import CashLens.TransactionsFixtures

    setup do
      %{card: account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10})}
    end

    test "an :estimado occurrence carries the month's installment total and groups", %{card: card} do
      recent =
        statement_fixture(%{
          account: card,
          due_date: Date.add(Date.utc_today(), -30),
          competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -30)),
          total_a_pagar: Decimal.new("2000.00")
        })

      assert recent.id

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "DISCLOSED_PARCEL",
          installments: 2,
          start_date: future_first,
          total_amount: Decimal.new("400.00")
        })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: group.id,
        installment_number: 1,
        date: future_first,
        amount: Decimal.new("-200.00")
      })

      [occ] = Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert occ.origin == :estimado

      assert Decimal.equal?(
               occ.installment_total,
               CashLens.Installments.account_installment_total(card.id, future_first)
             )

      assert [disclosed] = occ.installment_groups
      assert disclosed.description == "DISCLOSED_PARCEL"
      assert disclosed.parcel_number == 1
      assert disclosed.installments == 2
      assert Decimal.equal?(disclosed.parcel_value, Decimal.new("200.00"))
    end

    test "an :estimado occurrence with no installment in the month discloses nothing", %{
      card: card
    } do
      statement_fixture(%{
        account: card,
        due_date: Date.add(Date.utc_today(), -30),
        competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -30)),
        total_a_pagar: Decimal.new("2000.00")
      })

      future_first = Date.beginning_of_month(Date.add(Date.utc_today(), 60))
      [occ] = Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert occ.origin == :estimado
      assert Decimal.equal?(occ.installment_total, Decimal.new("0"))
      assert occ.installment_groups == []
    end

    test "a :boleto occurrence carries no installment breakdown", %{card: card} do
      statement_fixture(%{
        account: card,
        due_date: ~D[2026-08-10],
        competencia: ~D[2026-08-01],
        total_a_pagar: Decimal.new("1500.00")
      })

      [occ] = Forecast.card_occurrences(~D[2026-08-01], ~D[2026-08-31])

      assert occ.origin == :boleto
      assert Decimal.equal?(occ.installment_total, Decimal.new("0"))
      assert occ.installment_groups == []
    end
  end

  describe "temporary recurrences (off-card commitments)" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    alias CashLens.Installments

    setup do
      account_fixture(%{balance: "10000.00"})

      %{
        checking: account_fixture(%{balance: "0.00"}),
        card: account_fixture(%{balance: "0.00", is_credit_card: true})
      }
    end

    defp commitment_group(attrs) do
      {:ok, group} =
        Installments.create_installment_group(
          Enum.into(attrs, %{
            description_pattern: "COMPROMISSO",
            installments: 3,
            start_date: Date.utc_today(),
            total_amount: Decimal.new("1000.00")
          })
        )

      group
    end

    defp link(group, account) do
      transaction_fixture(%{
        account_id: account.id,
        installment_group_id: group.id,
        date: group.start_date,
        amount: Decimal.new("-1.00"),
        description: "parcela #{group.description_pattern}"
      })
    end

    defp commitment_occurrences(projection, group) do
      Enum.filter(projection.occurrences, &(Map.get(&1, :commitment)[:group_id] == group.id))
    end

    test "one occurrence per due month, amount equal to the negated rounded parcel value", %{
      checking: checking
    } do
      group = commitment_group(%{description_pattern: "FIN_OFF", commitment_type: "financing"})
      link(group, checking)

      occurrences = commitment_occurrences(Forecast.project(90), group)

      assert length(occurrences) == 3
      parcel = Installments.parcel_value(group)
      assert Decimal.equal?(parcel, Decimal.new("333.33"))

      assert Enum.all?(occurrences, &Decimal.equal?(&1.item.amount, Decimal.negate(parcel)))
      assert Enum.map(occurrences, & &1.commitment.parcel_number) == [1, 2, 3]
      assert Enum.all?(occurrences, &(&1.commitment.installments == 3))
      assert Enum.all?(occurrences, &(&1.item.label == "FIN_OFF"))
      refute Enum.any?(occurrences, & &1.item.is_salary)

      assert Enum.all?(
               occurrences,
               &(&1.commitment.ends_on == Installments.last_installment_date(group))
             )
    end

    test "the last occurrence is the final parcel and nothing is generated after it", %{
      checking: checking
    } do
      group =
        commitment_group(%{
          description_pattern: "FIN_END",
          installments: 2,
          start_date: Date.utc_today()
        })

      link(group, checking)

      occurrences = commitment_occurrences(Forecast.project(365), group)

      assert length(occurrences) == 2
      last = List.last(occurrences)
      assert last.commitment.parcel_number == 2
      assert last.commitment.installments == 2
      assert Date.compare(last.date, Installments.last_installment_date(group)) == :eq
    end

    test "a plan that already ended produces no occurrence", %{checking: checking} do
      group =
        commitment_group(%{
          description_pattern: "FIN_OLD",
          installments: 2,
          start_date: Date.add(Date.utc_today(), -365)
        })

      link(group, checking)

      assert commitment_occurrences(Forecast.project(365), group) == []
    end

    test "a group whose transactions sit on a credit card changes nothing in the chain", %{
      card: card
    } do
      recurring_item_fixture(%{day_of_month: Date.utc_today().day, amount: "-100.00"})

      baseline = Forecast.project(90)

      group = commitment_group(%{description_pattern: "CARD_BACKED"})
      link(group, card)

      after_group = Forecast.project(90)

      assert commitment_occurrences(after_group, group) == []
      assert chain(after_group) == chain(baseline)
    end

    test "membership ignores commitment_type", %{card: card, checking: checking} do
      financing_on_card =
        commitment_group(%{description_pattern: "FIN_ON_CARD", commitment_type: "financing"})

      link(financing_on_card, card)

      card_type_off_card =
        commitment_group(%{description_pattern: "CARD_OFF", commitment_type: "credit_card"})

      link(card_type_off_card, checking)

      projection = Forecast.project(90)

      assert commitment_occurrences(projection, financing_on_card) == []
      refute commitment_occurrences(projection, card_type_off_card) == []
    end

    test "a group with no linked transaction is included" do
      group = commitment_group(%{description_pattern: "SEM_LANCAMENTO"})

      refute commitment_occurrences(Forecast.project(90), group) == []
    end

    test "a consorcio projects identically whether contemplated or not", %{checking: checking} do
      group =
        commitment_group(%{description_pattern: "CONSORCIO", commitment_type: "consorcio"})

      link(group, checking)

      pending = commitment_occurrences(Forecast.project(90), group)

      {:ok, _} =
        Installments.update_installment_group(group, %{
          is_contemplated: true,
          contemplated_at: Date.utc_today()
        })

      contemplated = commitment_occurrences(Forecast.project(90), group)

      assert Enum.map(pending, &{&1.date, &1.item.amount, &1.commitment.parcel_number}) ==
               Enum.map(contemplated, &{&1.date, &1.item.amount, &1.commitment.parcel_number})
    end

    test "sync_all/0 creates no recurring item for a commitment", %{checking: checking} do
      group = commitment_group(%{description_pattern: "FIN_SYNC"})
      link(group, checking)

      before = Forecast.list_recurring_items()
      assert %{created: 0} = Forecast.sync_all()
      assert Forecast.list_recurring_items() == before
    end

    defp chain(projection) do
      Enum.map(projection.occurrences, &{&1.date, &1.item.amount, &1.balance_after})
    end
  end

  # Each claim printed next to the "Sincronizar Histórico" action, pinned to the
  # code so the copy cannot silently drift from what sync_all/0 really does.
  describe "the Sincronizar Histórico copy's claims" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "a fixed category with a single transaction in the window is left untouched" do
      category = category_fixture(%{type: "fixed", name: "Uma ocorrência só"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: Date.add(Date.utc_today(), -10),
        amount: "-30.00"
      })

      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
      assert Forecast.list_recurring_items() == []
    end

    test "only the last 180 days count towards the two required occurrences" do
      category = category_fixture(%{type: "fixed", name: "Janela de 180 dias"})
      account = account_fixture()

      for ago <- [10, 200] do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: Date.add(Date.utc_today(), -ago),
          amount: "-30.00"
        })
      end

      assert Forecast.suggest_for_category(category) == :insufficient_history
      assert Forecast.sync_all() == %{created: 0, updated: 0, deactivated: 0}
    end

    test "a manually edited item keeps its day and amount across sync_all/0" do
      category = category_fixture(%{type: "fixed", name: "Editado à mão"})
      account = account_fixture()

      for {ago, amount} <- [{10, "-90.00"}, {40, "-95.00"}] do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: Date.add(Date.utc_today(), -ago),
          amount: amount
        })
      end

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          label: "Editado à mão",
          day_of_month: 3,
          amount: "-42.00",
          manually_edited: true
        })

      assert %{updated: 0} = Forecast.sync_all()

      reloaded = Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 3
      assert Decimal.equal?(reloaded.amount, Decimal.new("-42.00"))
    end
  end

  describe "deactivate_superseded_items/0" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    defp grouped_spend(account, category, group, amount) do
      tx =
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          amount: amount,
          date: Date.add(Date.utc_today(), -30)
        })

      CashLens.Repo.update_all(
        from(t in CashLens.Transactions.Transaction, where: t.id == ^tx.id),
        set: [installment_group_id: group.id, installment_number: 1]
      )

      tx
    end

    defp commitment_group do
      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "COMPROMISSO #{System.unique_integer([:positive])}",
          commitment_type: "financing",
          installments: 60,
          start_date: Date.add(Date.utc_today(), -400),
          total_amount: "60000.00"
        })

      group
    end

    test "switches off an item whose category is wholly projected as a commitment" do
      account = account_fixture()
      category = category_fixture(%{type: "fixed", name: "Financiamento"})
      item = recurring_item_fixture(%{category_id: category.id, amount: "-1000.00"})
      group = commitment_group()

      grouped_spend(account, category, group, "-1000.00")

      assert [switched] = Forecast.deactivate_superseded_items()
      assert switched.id == item.id
      refute Forecast.get_recurring_item!(item.id).active
    end

    test "leaves an item alone while any debit in its category is unlinked" do
      account = account_fixture()
      category = category_fixture(%{type: "fixed", name: "Parcial"})
      item = recurring_item_fixture(%{category_id: category.id, amount: "-1000.00"})
      group = commitment_group()

      grouped_spend(account, category, group, "-1000.00")

      # One loose debit means the category still holds spending that only the
      # recurring item accounts for.
      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        amount: "-80.00",
        date: Date.add(Date.utc_today(), -5)
      })

      assert Forecast.deactivate_superseded_items() == []
      assert Forecast.get_recurring_item!(item.id).active
    end

    test "never touches an item edited by hand" do
      account = account_fixture()
      category = category_fixture(%{type: "fixed", name: "Na mao"})

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          amount: "-1000.00",
          manually_edited: true
        })

      group = commitment_group()
      grouped_spend(account, category, group, "-1000.00")

      assert Forecast.deactivate_superseded_items() == []
      assert Forecast.get_recurring_item!(item.id).active
    end

    test "leaves an item whose category has no transactions at all" do
      category = category_fixture(%{type: "fixed", name: "Vazia"})
      item = recurring_item_fixture(%{category_id: category.id, amount: "-1000.00"})

      assert Forecast.deactivate_superseded_items() == []
      assert Forecast.get_recurring_item!(item.id).active
    end

    test "registering a commitment switches the duplicate off on its own" do
      account = account_fixture()
      category = category_fixture(%{type: "fixed", name: "Consorcio"})
      item = recurring_item_fixture(%{category_id: category.id, amount: "-1400.00"})

      tx =
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          amount: "-1400.00",
          description: "BOLETO CONSORCIO PORTO",
          date: Date.add(Date.utc_today(), -30)
        })

      assert Forecast.get_recurring_item!(item.id).active

      {:ok, _group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "BOLETO CONSORCIO PORTO",
          commitment_type: "consorcio",
          installments: 60,
          start_date: Date.add(tx.date, -30),
          total_amount: "84000.00"
        })

      refute Forecast.get_recurring_item!(item.id).active
    end
  end

  describe "trough/2" do
    import CashLens.AccountsFixtures

    test "finds the lowest point of the daily curve, not the last one" do
      account_fixture(%{balance: "10000.00"})
      today = Date.utc_today()

      # A big debit early, repaid by income later: the curve dips and recovers,
      # so the worst day is in the middle and the final balance hides it.
      recurring_item_fixture(%{
        day_of_month: Date.add(today, 3).day,
        amount: "-9000.00",
        label: "Saida"
      })

      recurring_item_fixture(%{
        day_of_month: Date.add(today, 20).day,
        amount: "20000.00",
        label: "Entrada",
        is_salary: true
      })

      projection = Forecast.project(60)
      trough = Forecast.trough(projection, 60)

      assert Decimal.lt?(trough.balance, Forecast.final_balance(projection))
      assert Decimal.lt?(trough.balance, projection.starting_balance)
    end

    test "settles on the earliest day when the low point repeats" do
      account_fixture(%{balance: "500.00"})

      # Nothing moves, so every day of the horizon ties at the same balance and
      # the first of them must win.
      projection = Forecast.project(30)
      trough = Forecast.trough(projection, 30)

      assert trough.date == Date.utc_today()
    end
  end

  describe "monthly_volatility/2" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    defp net_in(account, month, amount) do
      transaction_fixture(%{account_id: account.id, date: month, amount: amount})
    end

    defp months_back(today, count) do
      last = today |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()
      index = last.year * 12 + last.month - 1

      Enum.map((count - 1)..0//-1, fn back ->
        total = index - back
        Date.new!(div(total, 12), rem(total, 12) + 1, 1)
      end)
    end

    test "measures how far the monthly net swings" do
      account = account_fixture()
      today = ~D[2026-10-06]
      meses = months_back(today, 12)

      # Six months at -1000 and six at -3000: mean -2000, every month exactly
      # 1000 away from it, so sigma is 1000.
      meses
      |> Enum.with_index()
      |> Enum.each(fn {mes, i} ->
        net_in(account, mes, if(rem(i, 2) == 0, do: "-1000.00", else: "-3000.00"))
      end)

      v = Forecast.monthly_volatility(12, today)

      assert Decimal.equal?(v.mean, Decimal.new("-2000.00"))
      assert Decimal.equal?(v.sigma, Decimal.new("1000.0"))
      assert v.months == 12
      assert v.since == List.first(meses)
    end

    test "leaves the current month out, since it is still accumulating" do
      account = account_fixture()
      today = ~D[2026-10-06]

      Enum.each(months_back(today, 12), &net_in(account, &1, "-2000.00"))

      # A single huge debit today must not register as volatility.
      net_in(account, today, "-90000.00")

      v = Forecast.monthly_volatility(12, today)

      assert Decimal.equal?(v.sigma, Decimal.new("0.0"))
      assert Decimal.equal?(v.mean, Decimal.new("-2000.00"))
    end

    test "returns nil without a full year of movement" do
      account = account_fixture()
      today = ~D[2026-10-06]

      Enum.each(months_back(today, 12), &net_in(account, &1, "0.00"))

      refute Forecast.monthly_volatility(12, today)
    end
  end

  describe "upcoming_bills/2" do
    import CashLens.AccountsFixtures
    import CashLens.CreditCardsFixtures

    setup do
      account_fixture(%{balance: "1000.00"})
      today = Date.utc_today()
      %{today: today}
    end

    defp bill_on(days_ahead, label, amount) do
      day = Date.utc_today() |> Date.add(days_ahead) |> Map.fetch!(:day)

      recurring_item_fixture(%{
        label: label,
        day_of_month: day,
        amount: amount,
        category_id: category_fixture(%{type: "fixed", name: label}).id
      })
    end

    test "lists the registered accounts falling due, soonest first" do
      # Days 1..3 ahead so the month cannot roll over mid-test.
      bill_on(3, "Condomínio", "-461.39")
      bill_on(1, "Gás", "-47.48")

      bills = Forecast.upcoming_bills(Forecast.project(10), 10)

      assert Enum.map(bills.shown, & &1.label) == ["Gás", "Condomínio"]
      assert Enum.map(bills.shown, & &1.kind) == [:recurring, :recurring]
      assert Decimal.equal?(bills.total, Decimal.new("508.87"))
    end

    test "the three summary lines partition exactly the money the list adds up" do
      bill_on(1, "Gás", "-47.48")
      bill_on(1, "Luz", "-334.16")
      bill_on(5, "Água", "-73.20")
      bill_on(12, "Seguro", "-147.69")

      bills = Forecast.upcoming_bills(Forecast.project(20), 20, 14, Date.utc_today())
      s = bills.summary

      assert s.next.count == 2
      assert s.next.date == Date.add(Date.utc_today(), 1)
      assert Decimal.equal?(s.next.total, Decimal.new("381.64"))

      # "Até 7 dias" excludes what the first line already counted.
      assert s.soon.count == 1
      assert Decimal.equal?(s.soon.total, Decimal.new("73.20"))

      assert s.later.count == 1
      assert s.later.last_date == Date.add(Date.utc_today(), 12)
      assert Decimal.equal?(s.later.total, Decimal.new("147.69"))

      sum = Enum.reduce([s.next, s.soon, s.later], Decimal.new(0), &Decimal.add(&2, &1.total))
      assert Decimal.equal?(sum, bills.total)
    end

    test "the soonest date is a date, not the whole of the first week" do
      bill_on(2, "Condomínio", "-461.39")
      bill_on(3, "Internet", "-241.99")

      summary = Forecast.upcoming_bills(Forecast.project(10), 10, 14, Date.utc_today()).summary

      assert summary.next.count == 1
      assert summary.next.date == Date.add(Date.utc_today(), 2)
      assert Decimal.equal?(summary.next.total, Decimal.new("461.39"))
      assert summary.soon.count == 1
    end

    test "with nothing due there is no summary to show" do
      assert Forecast.upcoming_bills(Forecast.project(10), 10, 14, Date.utc_today()).summary ==
               nil
    end

    test "leaves income out: this answers what is owed, not what the month looks like" do
      bill_on(1, "Luz", "-334.16")
      bill_on(2, "Salário", "35000.00")

      bills = Forecast.upcoming_bills(Forecast.project(10), 10)

      assert Enum.map(bills.shown, & &1.label) == ["Luz"]
      assert Decimal.equal?(bills.total, Decimal.new("334.16"))
    end

    test "a real unpaid statement is listed as a bill, and links to itself" do
      card =
        account_fixture(%{is_credit_card: true, name: "Ourocard", closing_day: 3, due_day: 10})

      due = Date.add(Date.utc_today(), 4)

      statement =
        statement_fixture(%{
          account: card,
          competencia: Date.beginning_of_month(due),
          due_date: due,
          total_a_pagar: Decimal.new("14075.87")
        })

      bills = Forecast.upcoming_bills(Forecast.project(20), 20)

      assert [bill] = Enum.filter(bills.shown, &(&1.kind == :statement))
      assert bill.label == "Fatura Ourocard"
      assert bill.statement_id == statement.id
      refute bill.estimated?
      assert Decimal.equal?(bill.amount, Decimal.new("14075.87"))
    end

    test "a statement already paid is not a bill to pay" do
      card = account_fixture(%{is_credit_card: true, name: "Amex", closing_day: 3, due_day: 10})
      conta = account_fixture(%{name: "Conta"})
      due = Date.add(Date.utc_today(), 4)

      statement =
        statement_fixture(%{
          account: card,
          competencia: Date.beginning_of_month(due),
          due_date: due,
          total_a_pagar: Decimal.new("100.00")
        })

      payment =
        CashLens.TransactionsFixtures.transaction_fixture(%{
          account_id: conta.id,
          amount: "-100.00",
          description: "PAGAMENTO FATURA"
        })

      {:ok, _} =
        CashLens.CreditCards.update_statement(statement, %{payment_transaction_id: payment.id})

      bills = Forecast.upcoming_bills(Forecast.project(20), 20)

      assert Enum.filter(bills.shown, &(&1.kind == :statement)) == []
    end

    test "what does not fit is counted and totalled, not dropped" do
      # The whole point of the tail: eight small bills can hold a fraction of
      # the month's money, and a tail that only counted rows would leave the
      # largest bill invisible behind a number of items.
      for day <- 1..4, do: bill_on(day, "Conta #{day}", "-10.00")

      bills = Forecast.upcoming_bills(Forecast.project(10), 10, 2)

      assert length(bills.shown) == 2
      assert bills.hidden_count == 2
      assert Decimal.equal?(bills.hidden_total, Decimal.new("20.00"))
      assert Decimal.equal?(bills.total, Decimal.new("40.00"))
      assert bills.last_date == Date.add(Date.utc_today(), 4)
    end

    test "nothing due is an empty list and a zero total" do
      bills = Forecast.upcoming_bills(Forecast.project(10), 10)

      assert bills.shown == []
      assert bills.hidden_count == 0
      assert Decimal.equal?(bills.total, Decimal.new(0))
      assert bills.last_date == nil
    end
  end
end
