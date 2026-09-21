defmodule CashLens.ForecastTest do
  use CashLens.DataCase, async: false

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem

  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures

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
        date: ~D[2026-04-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-12],
        amount: "-52.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
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

  describe "sync_all/0" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "creates an item for a fixed category with enough history" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-52.00"
      })

      assert Forecast.sync_all() == %{created: 1, updated: 0}
      assert [item] = Forecast.list_recurring_items()
      assert item.label == "Água"
      assert item.day_of_month == 10
    end

    test "does not create an item for a category with insufficient history" do
      category_fixture(%{type: "fixed", name: "Sem histórico"})

      assert Forecast.sync_all() == %{created: 0, updated: 0}
      assert Forecast.list_recurring_items() == []
    end

    test "ignores variable categories" do
      category_fixture(%{type: "variable", name: "Mercado"})

      assert Forecast.sync_all() == %{created: 0, updated: 0}
    end

    test "updates an existing non-manually-edited item, leaves manually-edited ones alone" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-60.00"
      })

      auto_item =
        recurring_item_fixture(%{category_id: category.id, day_of_month: 1, amount: "-1.00"})

      assert Forecast.sync_all() == %{created: 0, updated: 1}

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
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-60.00"
      })

      edited_item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert Forecast.sync_all() == %{created: 0, updated: 0}

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

      assert Forecast.sync_all() == %{created: 0, updated: 0}
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
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-20],
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

    test "zero_date is nil when the balance never goes negative" do
      recurring_item_fixture(%{day_of_month: 15, amount: "-1.00"})
      projection = Forecast.project()
      assert projection.zero_date == nil
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
      # variable = -2000 + 500 = -1500 ; estimate = -1500 - 200 = -1700
      assert Decimal.equal?(occ.item.amount, Decimal.new("-1700.00"))
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

      occurrences =
        CashLens.Forecast.card_occurrences(future_first, Date.end_of_month(future_first))

      assert [occ] = occurrences
      assert occ.origin == :estimado
      # If keyed by competencia (correct): variable = -2000 + 500 = -1500, no future
      # installments this month, so estimate stays -1500.00.
      # If keyed by due_date's month (the bug): the installment lands outside that
      # month, recent_installments would be 0, giving -2000.00 instead.
      assert Decimal.equal?(occ.item.amount, Decimal.new("-1500.00"))
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

      assert Forecast.sync_all() == %{created: 0, updated: 0}
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
      assert Forecast.sync_all() == %{created: 0, updated: 0}
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
end
