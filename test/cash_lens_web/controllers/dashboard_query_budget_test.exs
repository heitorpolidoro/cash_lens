defmodule CashLensWeb.DashboardQueryBudgetTest do
  @moduledoc """
  A query budget for `GET /`.

  The dashboard's cost is not a secret anybody keeps — it is simply that no test
  noticed it. This module notices. It builds a fixture set rich enough that
  every query group `CashLensWeb.PageController.home/2` has is actually
  exercised, renders the page, and asserts the number of queries that took, in
  total and per source table.

  The ceilings are a **measured baseline, not a target**: whatever today's code
  does is what is written down, so the module is green on arrival and
  `docs/tasks/CL-38-measurements.md` can say where each number comes from. Only
  a rise fails it. Bringing one down is the follow-up tasks' job, and each of
  them names the ceiling it has to reach.
  """
  # Never async. The counter filters by process, but a shared sandbox plus a
  # fixed numeric budget is no place to also be racing other tests.
  use CashLensWeb.ConnCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.CreditCardsFixtures
  import CashLens.ForecastFixtures
  import CashLens.TransactionsFixtures
  import Ecto.Query, only: [from: 2]

  alias CashLens.Accounting.Balance
  alias CashLens.Installments
  alias CashLens.QueryCounter
  alias CashLens.Repo

  # ---------------------------------------------------------------------------
  # The shape of the fixture set, as the ceilings' derivation needs it named.
  # ---------------------------------------------------------------------------

  # Open credit-card accounts with a full cycle (`closing_day` + `due_day`).
  # These are the cards `Forecast.card_occurrences/2` iterates.
  @cards 2

  # `Forecast.card_occurrences/2` walks one due-date per month inside the
  # 365-day horizon. That is **12 or 13** dates depending on where today falls
  # relative to `due_day`: when `due_day == today.day` the first date is today
  # and the twelfth-next lands exactly on the horizon's last day, so both are
  # inside it. The same calendar also decides whether the current month's
  # statement is one of the dates walked, which swaps one month between the
  # cheap `:boleto` branch and the expensive estimate branch.
  #
  # One extra due-month per card is therefore the *only* admissible margin, and
  # it is the only margin any ceiling below carries.
  @extra_due_months_per_card 1

  # What one card-due-month costs on the estimate branch, read off
  # `CashLens.Forecast`:
  #
  #   * `credit_card_statements`: 2 — `statement_for_month/2` (1) plus
  #     `estimate_for_month/2`'s recent-bill sample (1).
  #   * `installment_groups`: 8 — `estimate_for_month/2` calls
  #     `variable_part/1` once per sampled statement (`@estimate_sample`, 6
  #     here, each one `Installments.account_installment_total/2` →
  #     `account_installment_groups/2`), plus one more
  #     `account_installment_total/2` for the month being estimated, plus one
  #     `account_installment_groups/2` for the disclosure. 6 + 1 + 1 = 8.
  @statements_per_card_due_month 2
  @installment_groups_per_card_due_month 8

  # The per-card calendar margin, applied only to the two groups that scale
  # with the horizon and to the total they contribute to.
  @statements_delta @cards * @extra_due_months_per_card * @statements_per_card_due_month
  @installment_groups_delta @cards * @extra_due_months_per_card *
                              @installment_groups_per_card_due_month
  @total_delta @statements_delta + @installment_groups_delta

  # ---------------------------------------------------------------------------
  # The ceilings. Every one is `measured_fixture_count + delta`, measured on the
  # fixture set below. The measured column is the fixture set's number, not the
  # real database's — `docs/tasks/CL-38-measurements.md` records both and says
  # which is which.
  # ---------------------------------------------------------------------------

  # 282 measured + 20 = @total_delta, the two horizon-driven groups' share of
  # the calendar margin: 2 cards * 1 due-month * (2 + 8). Every other group
  # contributes 0 to it.
  @total_ceiling 282 + @total_delta

  # 177 measured + 16 = 2 cards * 1 due-month * 8. The measured 177 is
  # 22 estimating card-months * 8 + 1 for `list_off_card_groups/0`.
  @installment_groups_ceiling 177 + @installment_groups_delta

  # 47 measured + 4 = 2 cards * 1 due-month * 2. The measured 47 is 24
  # `statement_for_month/2` + 22 `estimate_for_month/2` samples + 1 for
  # `CreditCards.closed_without_statement/0`.
  @credit_card_statements_ceiling 47 + @statements_delta

  # 19 measured + 0: 12 for `Forecast.monthly_volatility/0`'s 12-month window,
  # 2 for `get_monthly_summary/0` (the latest-date probe and the aggregate), 2
  # for `get_historical_summary/1` (controller and `spend_rate/4`), 2 for
  # `overdue_occurrences/1` (the latest-date probe and `settled_categories/2`)
  # and 1 for `variable_spending_total/2`. Nothing here is driven by the
  # due-month calendar — every fixture statement carries a `total_a_pagar`, so
  # no bill falls back to `CreditCards.statement_transactions/1`, and an extra
  # due-month is always an estimate, which reads no transaction.
  @transactions_ceiling 19 + 0

  # 15 measured + 0: 12 for the three self-healing probes, which issue one
  # `exists?` per open account and there are 4, plus the two
  # `list_latest_balances/0` results and the one `get_historical_balances/1`.
  # Scales with the number of open accounts, not with the horizon.
  @balances_ceiling 15 + 0

  # 9 measured + 0: 3 for the self-healing probes' active-account list, 3 for
  # `Accounts.list_accounts/0` (`current_balance/0`, `card_accounts/0` and the
  # controller), 2 for the `:account` preload inside the two
  # `list_latest_balances/0` calls, and 1 for
  # `CreditCards.closed_without_statement/0`. Per caller, not per due-month.
  @accounts_ceiling 9 + 0

  # 2 measured + 0. `Forecast.list_recurring_items/0`, once in `project/2` and
  # once in `overdue_occurrences/1`.
  @recurring_items_ceiling 2 + 0

  # 13 measured + 0. `excluded_cash_summary_category_ids/0` costs 4 (two slug
  # lookups, two recursive CTEs) on each of the three summary reads, plus the
  # fixed-category lookup behind the variable baseline.
  @categories_ceiling 13 + 0

  setup do
    # Every date is derived from today. A fixture pinned to a literal year
    # stops reaching the 365-day horizon and the 12-month windows as the clock
    # moves, and the ceiling quietly stops measuring anything.
    today = Date.utc_today()
    this_month = Date.beginning_of_month(today)

    categories = build_categories()
    accounts = build_accounts()

    build_transactions(accounts, categories, today, this_month)
    build_statements(accounts, this_month)
    build_installment_groups(accounts, today, this_month)
    build_recurring_items(categories, today)

    # The balances are not written by hand: `Transactions.create_transaction/1`
    # recalculates the account's chain up to the current month, which is how
    # they appear in the real database too. What matters to the budget is that
    # every open account ends up with a balance for the current month, because
    # `Accounting.ensure_active_balances_healed/0` rebuilds the whole chain of
    # any open account missing one — self-healing work the dashboard does not
    # normally do, and which would drown the cost this budget measures. So it
    # is checked rather than assumed.
    assert_current_month_balances(accounts, this_month)

    %{today: today}
  end

  test "GET / stays inside its query budget", %{conn: conn} do
    {conn, counts} = QueryCounter.count(fn -> get(conn, ~p"/") end)

    assert html_response(conn, 200) =~ "Dashboard Financeiro"

    # Per table first: a regression that names the table it grew in is a
    # regression somebody can act on.
    assert_table(counts, "installment_groups", @installment_groups_ceiling)
    assert_table(counts, "credit_card_statements", @credit_card_statements_ceiling)
    assert_table(counts, "transactions", @transactions_ceiling)
    assert_table(counts, "balances", @balances_ceiling)
    assert_table(counts, "accounts", @accounts_ceiling)
    assert_table(counts, "recurring_items", @recurring_items_ceiling)
    assert_table(counts, "categories", @categories_ceiling)

    assert counts.total <= @total_ceiling,
           "GET / issued #{counts.total} queries, over the ceiling of #{@total_ceiling}. " <>
             "Per table: #{inspect(counts.by_table)}"
  end

  # Two-sided, and the lower bound is the load-bearing half. The tally is keyed
  # by source table, so a table the fixture set never reaches is absent from it
  # and a lone `0 <= ceiling` would pass while asserting nothing — the fixture
  # gap that caused it going green instead of red. `>= 1` is what makes "the
  # fixture set exercises every query group" a checked property; it is not a
  # second measured number, because only the upper bound is a budget.
  defp assert_table(counts, table, ceiling) do
    count = QueryCounter.for_table(counts, table)

    assert count >= 1,
           "GET / issued no query against #{table}: the fixture set no longer " <>
             "exercises that query group, so its ceiling asserts nothing."

    assert count <= ceiling,
           "GET / issued #{count} queries against #{table}, over the ceiling of #{ceiling}."
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp build_categories do
    %{
      # The dashboard's summaries exclude these two subtrees by slug, so their
      # presence is what makes `excluded_cash_summary_category_ids/0` run its
      # recursive CTE rather than stopping at a miss — as it does on real data.
      transfer: category_fixture(%{name: "Transferência", slug: "transfer", type: "variable"}),
      initial_value:
        category_fixture(%{name: "Saldo Inicial", slug: "initial_value", type: "variable"}),
      rent: category_fixture(%{name: "Aluguel", type: "fixed"}),
      gas: category_fixture(%{name: "Gás", type: "fixed"}),
      salary: category_fixture(%{name: "Salário", type: "fixed"}),
      groceries: category_fixture(%{name: "Mercado", type: "variable"})
    }
  end

  defp build_accounts do
    %{
      # Two open cards with a full cycle. Different `due_day`s so the two walk
      # different due-month calendars.
      card_a:
        account_fixture(%{
          name: "Cartão A",
          is_credit_card: true,
          closing_day: 5,
          due_day: 15
        }),
      card_b:
        account_fixture(%{
          name: "Cartão B",
          is_credit_card: true,
          closing_day: 10,
          due_day: 20
        }),
      cash_a: account_fixture(%{name: "Conta Corrente", balance: "2500.00"}),
      cash_b: account_fixture(%{name: "Investimentos", balance: "900.00", is_investment: true}),
      # A closed account, because the dashboard has to skip one: it is left out
      # of "Minhas Contas" and out of the self-healing probe's active-account
      # list. Its presence is what proves those exclusions are being taken.
      closed: account_fixture(%{name: "Conta Encerrada", is_closed: true})
    }
  end

  defp assert_current_month_balances(accounts, this_month) do
    for account <- [accounts.card_a, accounts.card_b, accounts.cash_a, accounts.cash_b] do
      assert Repo.exists?(
               from(b in Balance,
                 where:
                   b.account_id == ^account.id and b.year == ^this_month.year and
                     b.month == ^this_month.month
               )
             ),
             "#{account.name} has no balance for the current month, so rendering / " <>
               "would rebuild its whole chain and the budget would measure the rebuild."
    end
  end

  # Thirteen months of movement on every open account. The cash accounts feed
  # the KPIs, the chart, the 12-month history table and
  # `Forecast.monthly_volatility/0` — which runs one query per month of its
  # window and returns `nil` when every net is zero, taking the volatility
  # warning off the bankruptcy card. The amounts differ month to month so the
  # spread it measures is real.
  #
  # The cards get movement too, which is what gives them a balance chain and so
  # keeps the self-healing rebuild out of the render.
  defp build_transactions(accounts, categories, today, this_month) do
    for offset <- 0..12 do
      month = Installments.add_months(this_month, -offset)
      day = Date.new!(month.year, month.month, min(8, Date.days_in_month(month)))

      transaction_fixture(%{
        account_id: accounts.cash_a.id,
        amount: "#{3000 + offset * 37}.00",
        date: day,
        description: "Salário #{offset}",
        category_id: categories.salary.id
      })

      transaction_fixture(%{
        account_id: accounts.cash_a.id,
        amount: "-#{1500 + offset * 53}.00",
        date: day,
        description: "Aluguel #{offset}",
        category_id: categories.rent.id
      })

      transaction_fixture(%{
        account_id: accounts.cash_b.id,
        amount: "-#{200 + offset * 11}.00",
        date: day,
        description: "Mercado #{offset}",
        category_id: categories.groceries.id
      })

      for {card, label} <- [{accounts.card_a, "Cartão A"}, {accounts.card_b, "Cartão B"}] do
        transaction_fixture(%{
          account_id: card.id,
          amount: "-#{120 + offset * 7}.00",
          date: day,
          description: "Compra #{label} #{offset}",
          category_id: categories.groceries.id
        })
      end
    end

    # Dated today, so `Forecast.overdue_occurrences/1` has a ledger that
    # reaches past this month's due days and is allowed to call a bill unpaid.
    transaction_fixture(%{
      account_id: accounts.cash_a.id,
      amount: "-75.00",
      date: today,
      description: "Mercado hoje",
      category_id: categories.groceries.id
    })
  end

  # Six consecutive statements per card, current month back through five months
  # ago. Six is `Forecast`'s `@estimate_sample`, and five months back is well
  # inside the 180-day window `estimate_for_month/2` reads, so the sample is a
  # full six on every calendar day rather than drifting between five and six.
  # Some are paid and some are not: a paid statement produces no occurrence at
  # all, an unpaid one produces a `:boleto` instead of an estimate.
  defp build_statements(accounts, this_month) do
    for card <- [accounts.card_a, accounts.card_b], offset <- 0..5 do
      competencia = Installments.add_months(this_month, -offset)
      # The card's own `due_day`, read off the account rather than repeated, so
      # the statements cannot drift out of step with the cycle they belong to.
      due_date = Date.new!(competencia.year, competencia.month, card.due_day)

      payment =
        if offset in [1, 3] do
          transaction_fixture(%{
            account_id: accounts.cash_a.id,
            amount: "-#{900 + offset * 15}.00",
            date: due_date,
            description: "Pagamento #{card.name} #{offset}"
          }).id
        end

      # `account:`, not `account_id:` — `statement_fixture/1` creates a card of
      # its own for the former's default, and that stray open account would be
      # rebuilt by the self-healing probe on every render.
      statement_fixture(%{
        account: card,
        competencia: competencia,
        due_date: due_date,
        total_a_pagar: Decimal.new("#{900 + offset * 15}.00"),
        payment_transaction_id: payment
      })
    end
  end

  # One group on a card and one off it, because the two leave by different
  # doors: an on-card group is folded into the bill estimate by
  # `Installments.account_installment_total/2`, an off-card one becomes its own
  # occurrence through `Installments.list_off_card_groups/0`.
  defp build_installment_groups(accounts, today, this_month) do
    on_card = installment_group("GELADEIRA", Installments.add_months(this_month, -2), 12)

    transaction_fixture(%{
      account_id: accounts.card_a.id,
      amount: "-250.00",
      date: today,
      description: "GELADEIRA PARC 03/12",
      installment_group_id: on_card.id,
      installment_number: 3
    })

    off_card = installment_group("FINANCIAMENTO", Installments.add_months(this_month, -4), 24)

    transaction_fixture(%{
      account_id: accounts.cash_a.id,
      amount: "-480.00",
      date: today,
      description: "FINANCIAMENTO PARC 05/24",
      installment_group_id: off_card.id,
      installment_number: 5
    })
  end

  defp installment_group(pattern, start_date, installments) do
    {:ok, group} =
      Installments.create_installment_group(%{
        description_pattern: pattern,
        total_amount: "#{installments * 250}.00",
        installments: installments,
        start_date: start_date
      })

    group
  end

  # One salary, one ordinary bill, and one whose day has already passed with
  # nothing on its category this month — the overdue branch. On the 1st of a
  # month no day can have passed yet, so that branch has nothing to project;
  # it costs the same queries either way, which is what this budget measures.
  defp build_recurring_items(categories, today) do
    recurring_item_fixture(%{
      category_id: categories.salary.id,
      label: "Salário",
      day_of_month: 5,
      amount: "5000.00",
      is_salary: true
    })

    recurring_item_fixture(%{
      category_id: categories.rent.id,
      label: "Aluguel",
      day_of_month: 10,
      amount: "-1500.00"
    })

    recurring_item_fixture(%{
      category_id: categories.gas.id,
      label: "Gás",
      day_of_month: max(1, today.day - 1),
      amount: "-180.00"
    })
  end
end
