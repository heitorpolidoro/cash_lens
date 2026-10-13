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
  import Ecto.Query
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
      assert html =~ "Aberta"
      assert html =~ "Aguardando pagamento"
      assert html =~ "Paga e conciliada"
      assert html =~ "R$ 80,00"
      assert html =~ "R$ 2.400,40"
    end
  end

  describe "statements table" do
    setup do
      payment_category()
      nubank = card_account("Nubank")
      itau = card_account("Itau Card")

      a =
        statement_fixture(%{
          account: nubank,
          total_a_pagar: Decimal.new("100.00"),
          competencia: ~D[2026-05-01],
          due_date: ~D[2026-05-15]
        })

      b =
        statement_fixture(%{
          account: itau,
          total_a_pagar: Decimal.new("250.00"),
          competencia: ~D[2026-06-01],
          due_date: ~D[2026-06-15]
        })

      %{nubank: nubank, itau: itau, a: a, b: b}
    end

    test "lists every statement as a row", %{conn: conn, a: a, b: b} do
      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ ~s(data-role="statements-table")
      assert html =~ ~s(id="statement-row-#{a.id}")
      assert html =~ ~s(id="statement-row-#{b.id}")
    end

    test "search narrows the table by card name", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/statements")

      html = view |> form("form[phx-change='filter']", %{search: "Itau"}) |> render_change()

      assert html =~ ~s(id="statement-row-#{b.id}")
      refute html =~ ~s(id="statement-row-#{a.id}")
    end

    test "search finds a statement by its amount", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/statements")

      html = view |> form("form[phx-change='filter']", %{search: "250.00"}) |> render_change()

      assert html =~ ~s(id="statement-row-#{b.id}")
      refute html =~ ~s(id="statement-row-#{a.id}")
    end

    test "the card filter restricts to one card", %{conn: conn, a: a, b: b, nubank: nubank} do
      {:ok, view, _html} = live(conn, ~p"/statements")

      html = view |> form("form[phx-change='filter']", %{card: nubank.id}) |> render_change()

      assert html =~ ~s(id="statement-row-#{a.id}")
      refute html =~ ~s(id="statement-row-#{b.id}")
    end

    test "clearing the filters brings every row back", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/statements")

      view |> form("form[phx-change='filter']", %{search: "Itau"}) |> render_change()
      html = view |> element("button[phx-click='clear_filters']") |> render_click()

      assert html =~ ~s(id="statement-row-#{a.id}")
      assert html =~ ~s(id="statement-row-#{b.id}")
    end

    test "a reconciled statement shows its payment in the row", %{conn: conn, a: a} do
      bank = account_fixture(%{name: "Conta"})

      category =
        CashLens.Categories.get_category_by_slug(
          CashLens.Ownership.current_user!(),
          "cartao-de-credito"
        )

      payment =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "-100.00",
          date: ~D[2026-05-15],
          description: "PAGTO FATURA NUBANK"
        })

      assert Repo.get!(Statement, a.id).payment_transaction_id == payment.id

      {:ok, _view, html} = live(conn, ~p"/statements")

      # Visible without opening the statement -- the whole point of the column.
      assert html =~ "PAGTO FATURA NUBANK"
    end
  end

  describe "gaps" do
    test "reports a competência with no statement inside a card's range", %{conn: conn} do
      payment_category()
      card = card_account("Nubank")

      for comp <- [~D[2026-01-01], ~D[2026-03-01]] do
        statement_fixture(%{
          account: card,
          total_a_pagar: Decimal.new("10.00"),
          competencia: comp,
          due_date: Date.add(comp, 14)
        })
      end

      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ ~s(data-role="gap-missing")
      assert html =~ "Fev/26"
    end

    test "says nothing when the months are contiguous", %{conn: conn} do
      payment_category()
      card = card_account("Nubank")

      for comp <- [~D[2026-01-01], ~D[2026-02-01]] do
        statement_fixture(%{
          account: card,
          total_a_pagar: Decimal.new("10.00"),
          competencia: comp,
          due_date: Date.add(comp, 14)
        })
      end

      {:ok, _view, html} = live(conn, ~p"/statements")

      refute html =~ ~s(data-role="gap-missing")
    end
  end

  describe "manual statement" do
    setup do
      payment_category()
      %{card: card_account("Nubank"), bank: account_fixture(%{name: "Conta"})}
    end

    test "creates a statement with its lines and marks it manual", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/statements")

      view |> element("button[phx-click='new_statement']") |> render_click()

      html =
        view
        |> form("#new-statement-modal form", %{
          "account_id" => card.id,
          "competencia" => "2026-09",
          "due_date" => "2026-09-15",
          "total_a_pagar" => "80,50",
          "lines" => %{
            "0" => %{
              "date" => "2026-09-02",
              "description" => "COMPRA TESTE",
              "amount" => "80,50",
              "kind" => "compra"
            }
          }
        })
        |> render_submit()

      assert html =~ "Fatura criada."

      statement = Repo.one!(from(s in Statement, where: s.account_id == ^card.id))
      assert statement.source_file == "manual"
      assert statement.competencia == ~D[2026-09-01]
      assert Decimal.equal?(statement.total_a_pagar, "80.50")

      line = Repo.one!(from(t in Transaction, where: t.import_batch_id == ^statement.id))
      assert line.description == "COMPRA TESTE"
      # A purchase is stored negative on the card, from the "Compra" kind.
      assert Decimal.equal?(line.amount, "-80.50")
      assert line.account_id == card.id
    end

    test "a Crédito line is stored positive", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/statements")
      view |> element("button[phx-click='new_statement']") |> render_click()

      view
      |> form("#new-statement-modal form", %{
        "account_id" => card.id,
        "competencia" => "2026-09",
        "due_date" => "2026-09-15",
        "total_a_pagar" => "10,00",
        "lines" => %{
          "0" => %{
            "date" => "2026-09-02",
            "description" => "ESTORNO",
            "amount" => "25,00",
            "kind" => "credito"
          }
        }
      })
      |> render_submit()

      statement = Repo.one!(from(s in Statement, where: s.account_id == ^card.id))
      line = Repo.one!(from(t in Transaction, where: t.import_batch_id == ^statement.id))
      assert Decimal.equal?(line.amount, "25.00")
    end

    test "refuses a statement with neither competência nor due date", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/statements")
      view |> element("button[phx-click='new_statement']") |> render_click()

      html =
        view
        |> form("#new-statement-modal form", %{
          "account_id" => card.id,
          "competencia" => "",
          "due_date" => "",
          "total_a_pagar" => "10,00"
        })
        |> render_submit()

      assert html =~ "Informe a competência ou o vencimento"
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "refuses a statement with no card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/statements")
      view |> element("button[phx-click='new_statement']") |> render_click()

      html =
        view
        |> form("#new-statement-modal form", %{
          "account_id" => "",
          "competencia" => "2026-09",
          "total_a_pagar" => "10,00"
        })
        |> render_submit()

      assert html =~ "Escolha o cartão"
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "an existing payment of the exact amount is linked on creation", %{
      conn: conn,
      card: card,
      bank: bank
    } do
      category =
        CashLens.Categories.get_category_by_slug(
          CashLens.Ownership.current_user!(),
          "cartao-de-credito"
        )

      payment =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "-80.50",
          date: ~D[2026-09-15],
          description: "PAGTO FATURA"
        })

      {:ok, view, _html} = live(conn, ~p"/statements")
      view |> element("button[phx-click='new_statement']") |> render_click()

      view
      |> form("#new-statement-modal form", %{
        "account_id" => card.id,
        "competencia" => "2026-09",
        "due_date" => "2026-09-15",
        "total_a_pagar" => "80,50"
      })
      |> render_submit()

      statement = Repo.one!(from(s in Statement, where: s.account_id == ^card.id))
      assert statement.payment_transaction_id == payment.id
    end
  end

  describe "unlinked payments" do
    test "lists card-categorized transactions no statement claims", %{conn: conn} do
      payment_category()

      category =
        CashLens.Categories.get_category_by_slug(
          CashLens.Ownership.current_user!(),
          "cartao-de-credito"
        )

      bank = account_fixture(%{name: "Itau Conta"})

      loose =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "-321.00",
          date: ~D[2026-06-10],
          description: "PAGTO SOLTO"
        })

      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ ~s(data-role="unlinked-payments")
      assert html =~ "Sem fatura vinculada (1)"
      assert html =~ ~s(id="unlinked-#{loose.id}")
      assert html =~ "PAGTO SOLTO"
    end

    test "shows the empty state when everything is reconciled", %{conn: conn} do
      payment_category()

      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html =~ "Nenhum lançamento solto."
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

      category =
        CashLens.Categories.get_category_by_slug(
          CashLens.Ownership.current_user!(),
          "cartao-de-credito"
        )

      # Two exact payments: CreditCards.Matcher refuses to guess between them,
      # so the statement stays unpaid and the banner is what offers the choice.
      # A single exact payment would have been auto-linked on creation and the
      # banner would never render -- and a near-miss amount is no longer
      # announced as a detected payment at all.
      debit =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "-100.00",
          date: ~D[2026-06-14],
          description: "PAGAMENTO FATURA NUBANK"
        })

      transaction_fixture(%{
        account_id: bank.id,
        category_id: category.id,
        amount: "-100.00",
        date: ~D[2026-06-14],
        description: "PAGAMENTO FATURA NUBANK II"
      })

      # The first payment was auto-linked the moment it landed. Undoing that is
      # the operator action that puts the statement back in front of the
      # banner, now with two candidates to choose between.
      {:ok, _} =
        CashLens.CreditCards.unlink_payment(
          CashLens.Repo.get!(CashLens.CreditCards.Statement, statement.id)
        )

      {:ok, view, html} = live(conn, ~p"/statements")

      # The overview is a table now: the suggestion is a Conciliar button on
      # the statement's row, carrying the candidate in its title.
      assert html =~ "PAGAMENTO FATURA NUBANK"

      html =
        view
        |> element("#statement-row-#{statement.id} button[phx-click='link']")
        |> render_click()

      assert html =~ "Paga e conciliada"

      assert Repo.get!(Statement, statement.id).payment_transaction_id == debit.id
      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == debit.id
    end

    test "unlinking reverses the reconciliation", ctx do
      %{conn: conn, statement: statement, purchase: purchase, bank: bank} = ctx

      category =
        CashLens.Categories.get_category_by_slug(
          CashLens.Ownership.current_user!(),
          "cartao-de-credito"
        )

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

      assert html =~ "Aguardando pagamento"
      assert is_nil(Repo.get!(Statement, statement.id).payment_transaction_id)
      assert is_nil(Repo.get!(Transaction, purchase.id).parent_transaction_id)
    end

    test "renders no reconcile block and offers manual linking when no debit matches", ctx do
      %{conn: conn, statement: statement} = ctx

      {:ok, _view, html} = live(conn, ~p"/statements")

      refute html =~ "Pagamento Detectado no Extrato Bancário"
      assert html =~ "Aguardando pagamento"
      # With no candidate there is nothing to offer on the row either.
      refute html =~ "#statement-row-#{statement.id} button[phx-click='link']"

      {:ok, _view, detail} = live(conn, ~p"/statements?id=#{statement.id}")

      assert detail =~ "Vincular pagamento manualmente"
      assert detail =~ "Nenhum candidato"
    end

    test "manual linking through the candidate picker pays the statement", ctx do
      %{conn: conn, statement: statement, purchase: purchase, bank: bank} = ctx

      category =
        CashLens.Categories.get_category_by_slug(
          CashLens.Ownership.current_user!(),
          "cartao-de-credito"
        )

      other =
        transaction_fixture(%{
          account_id: bank.id,
          category_id: category.id,
          amount: "-999.00",
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

      {:ok, _view, html} = live(conn, ~p"/statements")

      # Every competência is a row in the table; there is no collapsed history.
      assert html =~ ~s(data-role="statements-table")
      assert html =~ CashLensWeb.Formatters.format_competencia(older.competencia)
      assert html =~ ~s(id="statement-row-#{older.id}")

      detail = live(conn, ~p"/statements?id=#{older.id}") |> elem(2)

      assert detail =~ "NOTEBOOK DELL"
      assert detail =~ "Parcela 3/10"
      refute is_nil(current.id)
    end

    test "includes a loose purchase in the statement and takes it back out", %{conn: conn} do
      account = card_account("Cartao Incluir")
      statement = statement_fixture(%{account: account, total_a_pagar: "500.00"})

      tx =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-123.45",
          description: "COMPRA SOLTA"
        })

      {:ok, view, html} = live(conn, ~p"/statements?id=#{statement.id}")
      assert html =~ "Incluir lançamentos na fatura"
      assert has_element?(view, "#attachable-#{tx.id}")

      render_click(view, "attach_transaction", %{"id" => tx.id})

      refute has_element?(view, "#attachable-#{tx.id}")
      assert has_element?(view, "#detach-#{tx.id}")
      assert CashLens.Transactions.get_transaction!(tx.id).import_batch_id == statement.id

      render_click(view, "detach_transaction", %{"id" => tx.id})

      assert has_element?(view, "#attachable-#{tx.id}")
      assert CashLens.Transactions.get_transaction!(tx.id).import_batch_id == nil
    end

    test "incorporates a statement into another and releases it again", %{conn: conn} do
      account = card_account("Cartao Incorporar")

      julho =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-07-01],
          due_date: ~D[2026-07-15]
        })

      agosto =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-08-01],
          due_date: ~D[2026-08-15]
        })

      {:ok, view, html} = live(conn, ~p"/statements?id=#{julho.id}")
      assert html =~ "Incorporar em outra fatura"

      render_submit(view, "absorb_into", %{"target_id" => agosto.id})

      assert CreditCards.get_statement!(julho.id).absorbed_by_statement_id == agosto.id
      assert render(view) =~ "Incorporada na fatura"
      assert has_element?(view, "#release-absorption")
      refute has_element?(view, "#absorb-into")

      render_click(view, "release_absorption", %{})

      assert CreditCards.get_statement!(julho.id).absorbed_by_statement_id == nil
      assert has_element?(view, "#absorb-into")
    end

    test "reports why an impossible absorption was refused", %{conn: conn} do
      account = card_account("Cartao A")
      julho = statement_fixture(%{account: account, competencia: ~D[2026-07-01]})

      outro = card_account("Cartao B")
      alheia = statement_fixture(%{account: outro, competencia: ~D[2026-08-01]})

      {:ok, view, _html} = live(conn, ~p"/statements?id=#{julho.id}")

      html = render_submit(view, "absorb_into", %{"target_id" => alheia.id})

      assert html =~ "precisam ser do mesmo cartão"
      assert CreditCards.get_statement!(julho.id).absorbed_by_statement_id == nil
    end

    test "the next-due card names every statement sharing the date", %{conn: conn} do
      um = card_account("Cartao Um")
      dois = card_account("Cartao Dois")
      vence = Date.add(Date.utc_today(), 5)

      for account <- [um, dois] do
        statement_fixture(%{
          account: account,
          competencia: Date.beginning_of_month(vence),
          due_date: vence,
          total_a_pagar: "300.00"
        })
      end

      {:ok, view, html} = live(conn, ~p"/statements")

      assert html =~ "Cartao Um"
      assert html =~ "Cartao Dois"
      assert view |> element("[data-role=\"next-due-total\"]") |> render() =~ "2 faturas"
    end

    test "a zero or negative bill offers no payment linking", %{conn: conn} do
      account = card_account("Cartao Zerado")
      zerada = statement_fixture(%{account: account, total_a_pagar: "0.00"})

      html = live(conn, ~p"/statements?id=#{zerada.id}") |> elem(2)
      refute html =~ "Vincular pagamento manualmente"

      paga = card_account("Cartao Com Saldo")
      devendo = statement_fixture(%{account: paga, total_a_pagar: "500.00"})

      html = live(conn, ~p"/statements?id=#{devendo.id}") |> elem(2)
      assert html =~ "Vincular pagamento manualmente"
    end

    test "detail view shows statement info", %{conn: conn} do
      account = card_account("Nubank Detalhe")
      statement = statement_fixture(%{account: account, total_a_pagar: nil})

      {:ok, _view, html} = live(conn, ~p"/statements?id=#{statement.id}")

      assert html =~ "Nubank Detalhe"
      assert html =~ statement.source_file
      assert html =~ "Aberta"
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

  describe "editing the statement total" do
    test "a closed statement offers the pencil, and saving a negative total sticks", %{conn: conn} do
      # The bank app produces no PDF for a negative bill, so the only way such a
      # statement exists is by hand -- and until now the total could only be
      # typed at creation.
      account = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-09-01],
          total_a_pagar: Decimal.new("0.00")
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      assert has_element?(live, "#edit-total")
      live |> element("#edit-total") |> render_click()

      live |> form("#total-form", %{"total_a_pagar" => "-112,28"}) |> render_submit()

      assert Repo.get!(Statement, statement.id).total_a_pagar
             |> Decimal.equal?(Decimal.new("-112.28"))
    end

    test "an empty total clears it to nil rather than storing zero", %{conn: conn} do
      # Blank and zero are different states: `nil` makes the forecast sum the
      # statement's own lines, while a stored 0 is taken as the bill itself and
      # projects nothing no matter what the statement holds.
      account = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-09-01],
          total_a_pagar: Decimal.new("50.00")
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      live |> element("#edit-total") |> render_click()
      live |> form("#total-form", %{"total_a_pagar" => ""}) |> render_submit()

      assert Repo.get!(Statement, statement.id).total_a_pagar == nil
    end

    test "zero is stored as zero, not read as blank", %{conn: conn} do
      account = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-09-01],
          total_a_pagar: Decimal.new("50.00")
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      live |> element("#edit-total") |> render_click()
      live |> form("#total-form", %{"total_a_pagar" => "0"}) |> render_submit()

      total = Repo.get!(Statement, statement.id).total_a_pagar
      refute is_nil(total)
      assert Decimal.equal?(total, Decimal.new("0"))
    end

    test "a value that is not a number is refused, leaving the total untouched", %{conn: conn} do
      account = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-09-01],
          total_a_pagar: Decimal.new("50.00")
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      live |> element("#edit-total") |> render_click()
      live |> form("#total-form", %{"total_a_pagar" => "abc"}) |> render_submit()

      assert has_element?(live, "#total-error")

      assert Repo.get!(Statement, statement.id).total_a_pagar
             |> Decimal.equal?(Decimal.new("50.00"))
    end

    test "a paid statement does not offer the pencil", %{conn: conn} do
      # Its total has been reconciled against the bank; editing it would move a
      # number the payment was matched against.
      account = card_account("Amazon")
      payment_category()

      statement =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-09-01],
          due_date: ~D[2026-09-10],
          total_a_pagar: Decimal.new("50.00")
        })

      payment =
        transaction_fixture(%{
          account_id: account_fixture(%{name: "Conta"}).id,
          amount: "-50.00",
          date: ~D[2026-09-10],
          description: "PAGAMENTO FATURA"
        })

      {:ok, _} = CreditCards.update_statement(statement, %{payment_transaction_id: payment.id})

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      refute has_element?(live, "#edit-total")
    end
  end

  describe "the attach section" do
    test "the attach section is shown empty rather than hidden", %{conn: conn} do
      # Hiding it made the feature look absent: someone looking for where to add
      # a purchase found no section at all and concluded it could not be done.
      account = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: account,
          competencia: ~D[2026-09-01],
          total_a_pagar: Decimal.new("0.00")
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      assert has_element?(live, "#attachable-transactions")
      assert render(live) =~ "Nenhuma compra avulsa neste cartão."
    end
  end

  describe "absorbed cycles on the absorbing statement" do
    setup do
      card = card_account("Amazon")

      boleto =
        statement_fixture(%{
          account: card,
          competencia: ~D[2026-10-01],
          due_date: ~D[2026-10-10],
          total_a_pagar: Decimal.new("300.00")
        })

      setembro = statement_fixture(%{account: card, competencia: ~D[2026-09-01], due_date: nil})
      agosto = statement_fixture(%{account: card, competencia: ~D[2026-08-01], due_date: nil})

      cycle_transaction(setembro, %{description: "COMPRA DE SETEMBRO", amount: "-66.28"})
      cycle_transaction(agosto, %{description: "COMPRA DE AGOSTO", amount: "-120.00"})

      {:ok, _} = CreditCards.absorb_into(setembro, boleto)
      {:ok, _} = CreditCards.absorb_into(agosto, boleto)

      %{card: card, boleto: boleto, setembro: setembro, agosto: agosto}
    end

    test "each absorbed cycle gets its own group, with its lines", %{
      conn: conn,
      boleto: boleto,
      setembro: setembro,
      agosto: agosto
    } do
      {:ok, live, _html} = live(conn, ~p"/statements?id=#{boleto.id}")

      assert has_element?(live, "#absorbed-group-#{agosto.id}")
      assert has_element?(live, "#absorbed-group-#{setembro.id}")

      html = render(live)
      assert html =~ "COMPRA DE AGOSTO"
      assert html =~ "COMPRA DE SETEMBRO"
    end

    test "the groups run oldest first", %{
      conn: conn,
      boleto: boleto,
      setembro: setembro,
      agosto: agosto
    } do
      {:ok, live, _html} = live(conn, ~p"/statements?id=#{boleto.id}")
      html = render(live)

      assert :binary.match(html, "absorbed-group-#{agosto.id}") <
               :binary.match(html, "absorbed-group-#{setembro.id}")
    end

    test "an absorbed line is not offered for detaching here", %{
      conn: conn,
      boleto: boleto,
      setembro: setembro
    } do
      # Detaching belongs on that cycle's own screen; from here it would move a
      # line out of a statement this screen is not editing.
      [line] = CreditCards.statement_transactions(setembro.id)

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{boleto.id}")

      refute has_element?(live, "#detach-#{line.id}")
    end

    test "a statement that absorbs nothing shows no groups", %{conn: conn, card: card} do
      solta =
        statement_fixture(%{
          account: card,
          competencia: ~D[2026-11-01],
          due_date: ~D[2026-11-10]
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{solta.id}")

      refute has_element?(live, "[id^='absorbed-group-']")
    end
  end

  describe "absorbing only rolls forward" do
    test "an earlier cycle is not offered as a target", %{conn: conn} do
      card = card_account("Amazon")

      julho =
        statement_fixture(%{account: card, competencia: ~D[2026-07-01], due_date: ~D[2026-07-15]})

      agosto =
        statement_fixture(%{account: card, competencia: ~D[2026-08-01], due_date: ~D[2026-08-15]})

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{agosto.id}")

      refute render(live) =~ "value=\"#{julho.id}\""
    end
  end

  describe "the global new-transaction button" do
    test "carries the card while a statement is open", %{conn: conn} do
      card = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: card,
          competencia: ~D[2026-10-01],
          due_date: ~D[2026-10-10]
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")

      assert has_element?(live, ~s{a[href="/transactions/new?for_account=#{card.id}"]})
    end

    test "drops the card when the user goes back to the hub", %{conn: conn} do
      # Leaving the detail is a patch, so the assign survives unless the no-id
      # clause clears it -- and the button would keep offering a card that is no
      # longer on screen.
      card = card_account("Amazon")

      statement =
        statement_fixture(%{
          account: card,
          competencia: ~D[2026-10-01],
          due_date: ~D[2026-10-10]
        })

      {:ok, live, _html} = live(conn, ~p"/statements?id=#{statement.id}")
      assert has_element?(live, ~s{a[href*="for_account"]})

      live |> element(~s{a[href="/statements"]}, "Voltar") |> render_click()

      refute has_element?(live, ~s{a[href*="for_account"]})
      assert has_element?(live, ~s{a[href="/transactions/new"]})
    end

    test "carries no card on the hub, where no statement is open", %{conn: conn} do
      card = card_account("Amazon")
      statement_fixture(%{account: card, competencia: ~D[2026-10-01]})

      {:ok, live, _html} = live(conn, ~p"/statements")

      assert has_element?(live, ~s{a[href="/transactions/new"]})
      refute has_element?(live, ~s{a[href*="for_account"]})
    end
  end

  describe "cycles with no statement yet" do
    import CashLens.AccountsFixtures

    test "every card appears for the current month, statement or not", %{conn: conn} do
      today = Date.utc_today()

      early = account_fixture(%{name: "Fecha Cedo", is_credit_card: true, closing_day: 1})
      late = account_fixture(%{name: "Fecha Tarde", is_credit_card: true, closing_day: 28})

      {:ok, live, _html} = live(conn, ~p"/statements")

      assert has_element?(live, "#pending-row-#{early.id}")
      assert has_element?(live, "#pending-row-#{late.id}")

      # Past its closing day the bill exists at the bank and is not here;
      # before it, there is nothing to expect yet.
      if today.day > 1 do
        assert has_element?(live, "#pending-row-#{early.id}", "Aguardando fatura")
      end

      if today.day < 28 do
        assert has_element?(live, "#pending-row-#{late.id}", "Ainda não fechou")
      end
    end

    test "a card whose statement already arrived has no pending row", %{conn: conn} do
      card = account_fixture(%{name: "Ourocard", is_credit_card: true, closing_day: 3})
      today = Date.utc_today()

      statement_fixture(%{
        account: card,
        competencia: Date.beginning_of_month(today),
        due_date: Date.add(today, 5),
        total_a_pagar: Decimal.new("1000.00")
      })

      {:ok, live, _html} = live(conn, ~p"/statements")

      refute has_element?(live, "#pending-row-#{card.id}")
      assert has_element?(live, "[id^='statement-row-']")
    end

    # It is a row about a statement that does not exist: there is nothing to
    # open, and nothing to reconcile a payment against.
    test "a pending row is not clickable", %{conn: conn} do
      card = account_fixture(%{name: "Ourocard", is_credit_card: true, closing_day: 3})

      {:ok, live, _html} = live(conn, ~p"/statements")

      refute has_element?(live, "#pending-row-#{card.id}[phx-click]")
      refute has_element?(live, "#pending-row-#{card.id}.cursor-pointer")
    end

    test "the status filter can ask for exactly the missing ones", %{conn: conn} do
      card = account_fixture(%{name: "Ourocard", is_credit_card: true, closing_day: 3})
      other = account_fixture(%{name: "Amex", is_credit_card: true, closing_day: 3})
      today = Date.utc_today()

      statement_fixture(%{
        account: other,
        competencia: Date.beginning_of_month(today),
        due_date: Date.add(today, 5),
        total_a_pagar: Decimal.new("1000.00")
      })

      {:ok, live, _html} = live(conn, ~p"/statements")

      live
      |> form("form[phx-change='filter']", %{"status" => "pending"})
      |> render_change()

      assert has_element?(live, "#pending-row-#{card.id}")
      refute has_element?(live, "[id^='statement-row-']")
    end
  end

  describe "zebra por mês" do
    import CashLens.AccountsFixtures

    test "the shading changes with the month, not with every row", %{conn: conn} do
      card = account_fixture(%{name: "Ourocard", is_credit_card: true, closing_day: 3})
      other = account_fixture(%{name: "Amex", is_credit_card: true, closing_day: 3})

      for competencia <- [~D[2026-08-01], ~D[2026-07-01]], account <- [card, other] do
        statement_fixture(%{
          account: account,
          competencia: competencia,
          due_date: Date.add(competencia, 9),
          total_a_pagar: Decimal.new("100.00")
        })
      end

      {:ok, _live, html} = live(conn, ~p"/statements")

      refute html =~ ~r/<tr[^>]*bg-base-200\/50/
      shaded = shaded_months(html)

      # Two cards per month: both rows of a month share one band, and the two
      # months do not. Striping every other row would split each month in half.
      assert Enum.count(shaded, &(&1 == "Ago/26")) in [0, 2]
      assert Enum.count(shaded, &(&1 == "Jul/26")) in [0, 2]
      assert "Ago/26" in shaded != "Jul/26" in shaded
    end

    defp shaded_months(html) do
      {:ok, re} = Regex.compile("<tr[^>]*bg-base-300/60[^>]*>(.*?)</tr>", "s")
      {:ok, month_re} = Regex.compile("<td[^>]*>\\s*([A-Z][a-z]{2}/\\d{2})\\s*</td>", "s")

      re
      |> Regex.scan(html)
      |> Enum.flat_map(fn [_, row] ->
        month_re |> Regex.scan(row) |> Enum.map(fn [_, month] -> month end)
      end)
    end
  end
end
