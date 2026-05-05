defmodule CashLensWeb.TransactionLive.ReimbursementLinkComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias CashLens.Transactions
  alias CashLensWeb.TransactionLive.ReimbursementLinkComponent
  alias Ecto.Adapters.SQL.Sandbox

  @create_attrs %{description: "some description", amount: 100, date: ~D[2026-03-01]}

  setup do
    {:ok, account} =
      CashLens.Accounts.create_account(%{
        name: "Checking",
        bank: "Bank A",
        balance: 0,
        accepts_import: true
      })

    {:ok, credit_tx} =
      Transactions.create_transaction(
        Map.merge(@create_attrs, %{account_id: account.id, amount: 100})
      )

    {:ok, expense_tx} =
      Transactions.create_transaction(
        Map.merge(@create_attrs, %{account_id: account.id, amount: -100})
      )

    {:ok, account: account, credit_tx: credit_tx, expense_tx: expense_tx}
  end

  defmodule HostLive do
    use Phoenix.LiveView
    alias CashLensWeb.TransactionLive.ReimbursementLinkComponent

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         reimbursement_credit: session["reimbursement_credit"],
         show: session["show"]
       )}
    end

    def handle_info(:reimbursement_linked, socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, :info, "linked")}
    end

    def handle_event(event, params, socket) do
      send_update(ReimbursementLinkComponent,
        id: "reimbursement-component",
        event: event,
        params: params
      )

      {:noreply, socket}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={ReimbursementLinkComponent}
        id="reimbursement-component"
        reimbursement_credit={@reimbursement_credit}
        show={@show}
      />
      """
    end
  end

  test "renders reimbursement modal", %{credit_tx: credit_tx} do
    {:ok, _view, html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "reimbursement_credit" => credit_tx,
          "show" => true
        }
      )

    assert html =~ "Vincular Reembolso"
  end

  test "links reimbursement", %{credit_tx: credit_tx, expense_tx: expense_tx} do
    Sandbox.mode(CashLens.Repo, {:shared, self()})

    {:ok, view, _html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "reimbursement_credit" => credit_tx,
          "show" => true
        }
      )

    # Find the button and click it directly using element
    view
    |> element("button[phx-value-expense-id='#{expense_tx.id}']")
    |> render_click()

    # Reload from DB
    updated_expense = Transactions.get_transaction!(expense_tx.id)
    assert updated_expense.reimbursement_status == "paid"
  end

  test "search reimbursement", %{credit_tx: credit_tx, expense_tx: expense_tx} do
    {:ok, view, _html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "reimbursement_credit" => credit_tx,
          "show" => true
        }
      )

    render_keyup(view, "reimbursement_search_change", %{
      "value" => "some",
      "myself" => "reimbursement-component"
    })

    assert render(view) =~ expense_tx.description
  end
end
