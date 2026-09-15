defmodule CashLensWeb.CreditCardStatementLiveTest do
  use CashLensWeb.ConnCase

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.CreditCardsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.CreditCards
  alias CashLens.CreditCards.Statement
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  defp card_account(name), do: account_fixture(%{is_credit_card: true, name: name})

  defp payment_category do
    category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
  end

  defp cycle_transaction(statement, attrs) do
    attrs
    |> Map.merge(%{account_id: statement.account_id, import_batch_id: statement.id})
    |> transaction_fixture()
  end

  defp days_label(0), do: "hoje"
  defp days_label(1), do: "em 1 dia"
  defp days_label(days), do: "em #{days} dias"

  describe "top metrics" do
    test "renders total due, awaiting count and next due date", %{conn: conn} do
      today = Date.utc_today()
      due = Date.end_of_month(today)
      account = card_account("Nubank")

      statement_fixture(%{
        account: account,
        due_date: due,
        competencia: Date.beginning_of_month(due),
        total_a_pagar: Decimal.new("3420.00")
      })

      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ "Total a Pagar"
      assert html =~ "R$ 3.420,00"
      assert html =~ "1 fatura"
      assert html =~ "Próximo Vencimento"
      assert html =~ CashLensWeb.Formatters.format_date(due)
      assert html =~ days_label(Date.diff(due, today))
      assert html =~ "Nubank"
    end

    test "does not count absorbed statements in the totals", %{conn: conn} do
      today = Date.utc_today()
      due = Date.end_of_month(today)
      account = card_account("Nubank")

      boleto =
        statement_fixture(%{
          account: account,
          due_date: due,
          competencia: Date.beginning_of_month(due),
          total_a_pagar: Decimal.new("3420.00")
        })

      absorbed =
        statement_fixture(%{
          account: account,
          due_date: nil,
          competencia: Date.beginning_of_month(due) |> Date.add(-1),
          total_a_pagar: Decimal.new("420.00")
        })

      {:ok, _} =
        absorbed |> Statement.changeset(%{absorbed_by_statement_id: boleto.id}) |> Repo.update()

      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ "R$ 3.420,00"
      refute html =~ "R$ 3.840,00"
      assert html =~ "1 fatura"
      assert html =~ "Incorporada"
    end
  end

  describe "grouping and lifecycle badges" do
    test "groups statements per card and badges Open, Closed and Paid", %{conn: conn} do
      open_account = card_account("Itau Card")
      closed_account = card_account("Inter Card")
      paid_account = card_account("Mercado Pago Card")
      bank = account_fixture(%{name: "Itau Conta"})

      open_statement =
        statement_fixture(%{
          account: open_account,
          total_a_pagar: nil,
          competencia: ~D[2026-03-01],
          due_date: ~D[2026-03-10]
        })

      cycle_transaction(open_statement, %{amount: "80.00", description: "Compra aberta"})

      statement_fixture(%{
        account: closed_account,
        total_a_pagar: Decimal.new("2400.40"),
        competencia: ~D[2026-03-01],
        due_date: ~D[2026-03-20]
      })

      payment =
        transaction_fixture(%{
          account_id: bank.id,
          amount: "850.00",
          description: "PAGAMENTO FATURA",
          date: ~D[2026-03-09]
        })

      paid_statement =
        statement_fixture(%{
          account: paid_account,
          total_a_pagar: Decimal.new("850.00"),
          competencia: ~D[2026-03-01],
          due_date: ~D[2026-03-10]
        })

      {:ok, _} = CreditCards.link_payment(paid_statement, payment.id)

      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ "Itau Card"
      assert html =~ "Inter Card"
      assert html =~ "Mercado Pago Card"
      assert html =~ "Aberta (Em Curso)"
      assert html =~ "Fechada (Aguardando Pagamento)"
      assert html =~ "Paga e Conciliada"
      assert html =~ "R$ 80,00"
      assert html =~ "R$ 2.400,40"
    end
  end

  describe "one-click reconciliation" do
    setup do
      payment_category()
      account = card_account("Nubank")
      bank = account_fixture(%{name: "Itau Conta"})

      statement =
        statement_fixture(%{
          account: account,
          total_a_pagar: Decimal.new("100.00"),
          competencia: ~D[2026-06-01],
          due_date: ~D[2026-06-15]
        })

      purchase = cycle_transaction(statement, %{amount: "100.00", description: "Compra do ciclo"})

      %{statement: statement, purchase: purchase, bank: bank, account: account}
    end

    test "renders the reconcile block and links the payment in one click", ctx do
      %{conn: conn, statement: statement, purchase: purchase, bank: bank} = ctx
      category = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      debit =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "99.50",
          date: ~D[2026-06-14],
          description: "PAGAMENTO FATURA NUBANK"
        })

      {:ok, view, html} = live(conn, ~p"/statements")

      assert html =~ "Pagamento Detectado no Extrato Bancário"
      assert html =~ "PAGAMENTO FATURA NUBANK"

      html =
        view
        |> element("#reconcile-#{statement.id} button")
        |> render_click()

      assert html =~ "Paga e Conciliada"
      refute html =~ "Pagamento Detectado no Extrato Bancário"

      assert Repo.get!(Statement, statement.id).payment_transaction_id == debit.id
      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == debit.id
    end

    test "unlinking reverses the reconciliation", ctx do
      %{conn: conn, statement: statement, purchase: purchase, bank: bank} = ctx
      category = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      debit =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "99.50",
          date: ~D[2026-06-14],
          description: "PAGAMENTO FATURA NUBANK"
        })

      {:ok, _} = CreditCards.link_payment(statement, debit.id)

      {:ok, view, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      html = view |> element("button", "Desvincular") |> render_click()

      assert html =~ "Fechada (Aguardando Pagamento)"
      assert is_nil(Repo.get!(Statement, statement.id).payment_transaction_id)
      assert is_nil(Repo.get!(Transaction, purchase.id).parent_transaction_id)
    end

    test "renders no reconcile block and offers manual linking when no debit matches", ctx do
      %{conn: conn, statement: statement} = ctx

      {:ok, _view, html} = live(conn, ~p"/statements")

      refute html =~ "Pagamento Detectado no Extrato Bancário"
      assert html =~ "Fechada (Aguardando Pagamento)"
      assert html =~ "Nenhum débito bancário compatível encontrado"
      assert html =~ "Vincular pagamento manualmente"

      {:ok, _view, detail} = live(conn, ~p"/statements?id=#{statement.id}")

      assert detail =~ "Vincular pagamento manualmente"
      assert detail =~ "Nenhum candidato"
    end

    test "manual linking through the candidate picker pays the statement", ctx do
      %{conn: conn, statement: statement, purchase: purchase, bank: bank} = ctx
      category = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      other =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "999.00",
          date: ~D[2026-06-14],
          description: "PAGTO DEBITO AUTOMATICO"
        })

      {:ok, view, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      html =
        view
        |> element("#candidate-#{other.id} button")
        |> render_click()

      assert html =~ "Paga"
      assert Repo.get!(Statement, statement.id).payment_transaction_id == other.id
      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == other.id
    end
  end

  describe "history and detail" do
    test "lists earlier competências and opens their transactions with installments", %{
      conn: conn
    } do
      account = card_account("Nubank")

      current =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-06-01],
          due_date: ~D[2026-06-15],
          total_a_pagar: Decimal.new("100.00")
        })

      older =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-05-01],
          due_date: ~D[2026-05-15],
          total_a_pagar: Decimal.new("55.00")
        })

      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "NOTEBOOK DELL",
          total_amount: Decimal.new("4999.00"),
          installments: 10,
          start_date: ~D[2026-03-05]
        })

      transaction_fixture(%{
        account_id: account.id,
        import_batch_id: older.id,
        amount: "499.90",
        date: ~D[2026-05-05],
        description: "NOTEBOOK DELL",
        installment_group_id: group.id,
        installment_number: 3
      })

      {:ok, view, html} = live(conn, ~p"/statements")

      assert html =~ "Histórico por competência"
      assert html =~ CashLensWeb.Formatters.format_competencia(older.competencia)

      detail =
        view
        |> element(~s{a[href="/statements?id=#{older.id}"]})
        |> render_click()

      assert detail =~ "NOTEBOOK DELL"
      assert detail =~ "Parcela 3/10"
      refute is_nil(current.id)
    end

    test "detail view shows statement info", %{conn: conn} do
      account = card_account("Nubank Detalhe")
      statement = statement_fixture(%{account: account, total_a_pagar: nil})

      {:ok, _view, html} = live(conn, ~p"/statements?id=#{statement.id}")

      assert html =~ "Nubank Detalhe"
      assert html =~ statement.source_file
      assert html =~ "Aberta (Em Curso)"
    end

    test "detail view for an absorbed statement links the absorbing boleto", %{conn: conn} do
      account = card_account("Amazon")

      boleto =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-07-01],
          source_file: "boleto.pdf"
        })

      statement =
        statement_fixture(%{
          account: account,
          due_date: nil,
          competencia: ~D[2026-06-01]
        })

      {:ok, _} =
        statement |> Statement.changeset(%{absorbed_by_statement_id: boleto.id}) |> Repo.update()

      {:ok, _view, html} = live(conn, ~p"/statements?id=#{statement.id}")

      assert html =~ "Incorporada"
    end
  end

  test "redirect from old path", %{conn: conn} do
    conn = get(conn, ~p"/credit_card_links")
    assert redirected_to(conn) == ~p"/statements"
  end
end
