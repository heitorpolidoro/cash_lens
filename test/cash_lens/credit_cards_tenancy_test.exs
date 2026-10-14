defmodule CashLens.CreditCardsTenancyTest do
  @moduledoc """
  User B never reads, changes or links user A's credit-card statements,
  payments or the transactions behind them.

  Calls made for B run with the process pinned to A on purpose: row-level
  security would then let A's rows through, so what keeps them out of B's
  results is only the application-level `Ownership.scope/2` filter.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.CreditCardsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.CreditCards
  alias CashLens.CreditCards.Matcher
  alias CashLens.CreditCards.Statement
  alias CashLens.Tenancy
  alias CashLens.Transactions.Transaction

  @today ~D[2026-10-13]
  @meta %{due_date: nil, total_a_pagar: nil, competencia: ~D[2026-06-01]}

  setup do
    %{a: a, b: b} = cross_tenant()

    Tenancy.acting_as(a, fn ->
      card = account_fixture(%{user: a, is_credit_card: true, closing_day: 5, due_day: 15})
      bank = account_fixture(%{user: a})
      cat = category_fixture(%{user: a, name: "Cartão", slug: "cartao-de-credito"})

      # The payment exists before the statement, so nothing links them yet.
      payment =
        transaction_fixture(%{
          user: a,
          account_id: bank.id,
          amount: "-100.00",
          date: ~D[2026-06-16],
          description: "pagamento fatura",
          category_id: cat.id
        })

      stmt = fn attrs ->
        statement_fixture(Map.merge(%{user: a, account: card}, attrs))
      end

      # The competência is wrong on purpose: recomputing fixes it.
      s1 =
        stmt.(%{
          competencia: ~D[2026-01-01],
          due_date: ~D[2026-06-15],
          total_a_pagar: Decimal.new("100.00")
        })

      s2 =
        stmt.(%{
          competencia: ~D[2026-07-01],
          due_date: ~D[2026-07-15],
          total_a_pagar: Decimal.new("20.00")
        })

      s3 =
        stmt.(%{competencia: ~D[2026-02-01], due_date: nil, total_a_pagar: Decimal.new("30.00")})

      {:ok, s3} = CreditCards.update_statement(a, s3, %{absorbed_by_statement_id: s2.id})

      s4 =
        stmt.(%{competencia: ~D[2026-03-01], due_date: nil, total_a_pagar: Decimal.new("20.00")})

      a_line =
        transaction_fixture(%{
          user: a,
          account_id: card.id,
          amount: "-100.00",
          date: ~D[2026-06-01],
          description: "compra",
          import_batch_id: s1.id
        })

      loose =
        transaction_fixture(%{
          user: a,
          account_id: card.id,
          amount: "-9.00",
          date: ~D[2026-06-02],
          description: "avulsa"
        })

      b_card = account_fixture(%{user: b, is_credit_card: true, name: "B card"})
      b_bank = account_fixture(%{user: b})

      b_stmt =
        statement_fixture(%{
          user: b,
          account: b_card,
          competencia: ~D[2026-06-01],
          due_date: ~D[2026-06-15],
          total_a_pagar: Decimal.new("55.00")
        })

      # Same amount and window as A's first statement. B has no card-payment
      # category of its own (slugs are unique), so it must never match.
      b_payment =
        transaction_fixture(%{
          user: b,
          account_id: b_bank.id,
          amount: "-100.00",
          date: ~D[2026-06-16],
          description: "pagamento B"
        })

      %{
        a: a,
        b: b,
        card: card,
        s1: s1,
        s2: s2,
        s3: s3,
        s4: s4,
        payment: payment,
        a_line: a_line,
        loose: loose,
        b_card: b_card,
        b_stmt: b_stmt,
        b_payment: b_payment
      }
    end)
  end

  # B's calls run while the process is pinned to A.
  defp as_b(a, fun), do: Tenancy.acting_as(a, fun)

  # A's persisted state, read as A.
  defp snapshot(a) do
    Tenancy.acting_as(a, fn ->
      {Repo.all(from s in Statement, order_by: s.id),
       Repo.all(from t in Transaction, order_by: t.id)}
    end)
  end

  defp b_state(b) do
    Tenancy.acting_as(b, fn ->
      {Repo.all(from s in Statement, order_by: s.id),
       Repo.all(from t in Transaction, order_by: t.id)}
    end)
  end

  describe "user B cannot read user A's statements" do
    test "lists are empty", %{
      a: a,
      b: b,
      card: card,
      s1: s1,
      s2: s2,
      s3: s3,
      payment: payment
    } do
      as_b(a, fn ->
        assert CreditCards.list_statements(b) == []
        assert CreditCards.list_boletos_for_account(b, card.id) == []
        assert CreditCards.statement_transactions(b, s1.id) == []
        assert CreditCards.absorbed_groups(b, s2.id) == []
        assert CreditCards.absorption_targets(b, s1) == []

        assert CreditCards.get_statement_by_account_and_competencia(b, card.id, s1.competencia) ==
                 nil

        assert CreditCards.get_statement_paid_by(b, payment.id) == nil
        assert CreditCards.pending_cycles(b, [], @today) == []

        # B's card has no billing cycle, and A's closed cycles are not B's.
        assert CreditCards.closed_without_statement(b, @today) == []

        assert CreditCards.get_statement(b, s3.id) == nil
      end)
    end

    test "B sees only its own statement and card", %{b: b, b_card: b_card, b_stmt: b_stmt} do
      Tenancy.acting_as(b, fn ->
        assert [%{statement: %{id: id}}] = CreditCards.list_statements(b)
        assert id == b_stmt.id
        assert [%{account: %{id: account_id}}] = CreditCards.pending_cycles(b, [], @today)
        assert account_id == b_card.id
      end)
    end

    test "closed cycles without a statement are A's own", %{a: a, card: card} do
      Tenancy.acting_as(a, fn ->
        assert [%{account: %{id: id}} | _] = CreditCards.closed_without_statement(a, @today)
        assert id == card.id
      end)
    end

    test "candidates, suggestions and loose lines for A's statement are empty", %{
      a: a,
      b: b,
      s1: s1
    } do
      as_b(a, fn ->
        assert CreditCards.payment_candidates(b, s1) == []
        assert CreditCards.suggest_payment(b, s1) == nil
        assert CreditCards.attachable_transactions(b, s1) == []
        assert CreditCards.unlinked_card_payments(b) == []
      end)

      Tenancy.acting_as(a, fn ->
        assert [_] = CreditCards.payment_candidates(a, s1)
      end)
    end

    test "getters raise Ecto.NoResultsError", %{a: a, b: b, s1: s1} do
      as_b(a, fn ->
        assert_raise Ecto.NoResultsError, fn -> CreditCards.get_statement!(b, s1.id) end
        assert_raise Ecto.NoResultsError, fn -> CreditCards.get_statement_detail(b, s1.id) end
      end)
    end
  end

  describe "user B cannot change user A's statements" do
    test "writes on A's statement, payment, line and account answer :not_found", %{
      a: a,
      b: b,
      card: card,
      s1: s1,
      s2: s2,
      s3: s3,
      payment: payment,
      a_line: a_line,
      loose: loose,
      b_stmt: b_stmt
    } do
      before = snapshot(a)

      as_b(a, fn ->
        assert {:error, :not_found} = CreditCards.update_statement(b, s1, %{total_a_pagar: "1"})
        assert {:error, :not_found} = CreditCards.link_payment(b, s1, payment.id)
        assert {:error, :not_found} = CreditCards.unlink_payment(b, s1)
        assert {:error, :not_found} = CreditCards.attach_transactions(b, s1, [loose.id])
        assert {:error, :not_found} = CreditCards.detach_transaction(b, s1, a_line.id)
        assert {:error, :not_found} = CreditCards.absorb_into(b, s1, s2)
        assert {:error, :not_found} = CreditCards.release_absorption(b, s3)
        assert {:error, :not_found} = CreditCards.reset_account_statements(b, card.id)
        assert {:error, :not_found} = CreditCards.backfill_file(b, card, [], @meta, "x.pdf")

        # B's own statement against A's rows.
        assert {:error, :not_found} = CreditCards.link_payment(b, b_stmt, payment.id)
        assert {:error, :not_found} = CreditCards.attach_transactions(b, b_stmt, [loose.id])
        assert {:error, :not_found} = CreditCards.detach_transaction(b, b_stmt, a_line.id)
        assert {:error, :not_found} = CreditCards.absorb_into(b, b_stmt, s2)
        assert {:error, :not_found} = CreditCards.absorb_into(b, s1, b_stmt)
      end)

      assert snapshot(a) == before
    end

    test "reconcile and recompute only touch B's own rows", %{a: a, b: b} do
      before = snapshot(a)

      as_b(a, fn ->
        assert CreditCards.reconcile_pending(b) == 0
        assert CreditCards.recompute_competencia(b) == 0
      end)

      assert snapshot(a) == before
    end

    test "reconcile and recompute do change A's rows for A (the checks above have teeth)", %{
      a: a,
      s4: s4
    } do
      Tenancy.acting_as(a, fn ->
        assert CreditCards.recompute_competencia(a) == 1
        assert CreditCards.reconcile_pending(a) == 1
        assert CreditCards.get_statement!(a, s4.id).absorbed_by_statement_id
      end)
    end

    test "the matcher never links A's payment to A's statement for B", %{
      a: a,
      b: b,
      s1: s1,
      payment: payment,
      b_payment: b_payment
    } do
      before = snapshot(a)

      as_b(a, fn ->
        # B's payment has the amount and window of A's statement, not of its own.
        assert Matcher.match_payment(b, b_payment) == :not_credit_card_category
        assert Matcher.match_payment(b, payment) == :not_credit_card_category
        assert Matcher.match_payment(b, b_payment, s1.account_id) == :not_credit_card_category
        assert Matcher.auto_link(b, s1, Decimal.new("100.00")) == :no_match
      end)

      assert snapshot(a) == before
    end

    test "the matcher still links the owner's own payment", %{a: a, s1: s1, payment: payment} do
      Tenancy.acting_as(a, fn ->
        assert {:linked, linked} = Matcher.auto_link(a, s1, Decimal.new("100.00"))
        assert linked.id == payment.id
      end)
    end
  end

  describe "statements cannot point at someone else's rows" do
    test "a foreign account is a changeset error and nothing is inserted", %{
      b: b,
      card: card
    } do
      before = b_state(b)

      Tenancy.acting_as(b, fn ->
        assert {:error, changeset} =
                 CreditCards.create_statement(b, %{
                   account_id: card.id,
                   competencia: ~D[2026-08-01]
                 })

        assert %{account_id: ["does not exist"]} = errors_on(changeset)

        assert {:error, changeset} =
                 CreditCards.create_manual_statement(
                   b,
                   %{account_id: card.id, competencia: ~D[2026-08-01]},
                   [%{date: ~D[2026-08-02], description: "x", amount: Decimal.new("-1")}]
                 )

        assert %{account_id: ["does not exist"]} = errors_on(changeset)
      end)

      assert b_state(b) == before
    end

    test "a foreign payment transaction is a changeset error", %{
      b: b,
      payment: payment,
      b_card: b_card,
      b_stmt: b_stmt
    } do
      before = b_state(b)

      Tenancy.acting_as(b, fn ->
        assert {:error, changeset} =
                 CreditCards.create_statement(b, %{
                   account_id: b_card.id,
                   competencia: ~D[2026-08-01],
                   payment_transaction_id: payment.id
                 })

        assert %{payment_transaction_id: ["does not exist"]} = errors_on(changeset)

        assert {:error, changeset} =
                 CreditCards.update_statement(b, b_stmt, %{payment_transaction_id: payment.id})

        assert %{payment_transaction_id: ["does not exist"]} = errors_on(changeset)
      end)

      assert b_state(b) == before
    end

    test "a user_id in the attrs is ignored", %{a: a, b: b, b_card: b_card} do
      Tenancy.acting_as(b, fn ->
        assert {:ok, statement} =
                 CreditCards.create_statement(b, %{
                   account_id: b_card.id,
                   competencia: ~D[2026-09-01],
                   user_id: a.id
                 })

        assert statement.user_id == b.id
      end)
    end
  end
end
