defmodule CashLensWeb.CreditCardLinkLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  defp cc_category, do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

  test "shows an orphan batch under 'Sem Pai Encontrado'", %{conn: conn} do
    card = account_fixture(%{is_credit_card: true})
    transaction_fixture(%{account_id: card.id, amount: "-30.00", date: ~D[2026-03-01]})

    {:ok, _view, html} = live(conn, ~p"/credit_card_links")
    assert html =~ "Sem Pai Encontrado"
    assert html =~ "-30"
  end

  test "shows a divergent pair under 'Vinculados com Divergência'", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    payment =
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-200.00",
        date: ~D[2026-03-05]
      })

    child = transaction_fixture(%{account_id: card.id, amount: "-150.00", date: ~D[2026-03-01]})
    Transactions.link_credit_card_batch([child.id], payment.id)

    {:ok, _view, html} = live(conn, ~p"/credit_card_links")
    assert html =~ "Vinculados com Divergência"
  end

  test "confirming a suggestion links the batch", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    purchase =
      transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})

    payment =
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-100.00",
        date: ~D[2026-06-01]
      })

    {:ok, view, _html} = live(conn, ~p"/credit_card_links")

    view
    |> element("button[phx-click='confirm_suggestion'][phx-value-payment-id='#{payment.id}']")
    |> render_click()

    assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
  end

  test "manually linking an orphan batch via the modal sets the parent", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    purchase =
      transaction_fixture(%{account_id: card.id, amount: "-30.00", date: ~D[2026-03-01]})

    payment =
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-999.00",
        date: ~D[2026-06-01]
      })

    {:ok, view, _html} = live(conn, ~p"/credit_card_links")

    batch = List.first(Transactions.list_credit_card_orphan_batches())

    view
    |> element(
      "button[phx-click='open_batch_link'][phx-value-batch-account-id='#{batch.account_id}']"
    )
    |> render_click()

    assert has_element?(view, "#batch-link-modal")
    assert render(view) =~ payment.description

    html =
      view
      |> element("button[phx-click='link_batch'][phx-value-payment-id='#{payment.id}']")
      |> render_click()

    refute has_element?(view, "#batch-link-modal")
    assert html =~ "vinculada"
    assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
  end

  test "unlinking a pair clears the children", %{conn: conn} do
    cc = cc_category()
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    payment =
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-100.00",
        date: ~D[2026-03-05]
      })

    child = transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-03-01]})
    Transactions.link_credit_card_batch([child.id], payment.id)

    {:ok, view, _html} = live(conn, ~p"/credit_card_links")

    view
    |> element("button[phx-click='unlink'][phx-value-id='#{payment.id}']")
    |> render_click()

    assert is_nil(Repo.get!(Transaction, child.id).parent_transaction_id)
  end
end
