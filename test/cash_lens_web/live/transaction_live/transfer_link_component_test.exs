defmodule CashLensWeb.TransactionLive.TransferLinkComponentTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest
  alias CashLens.Transactions
  alias CashLensWeb.TransactionLive.TransferLinkComponent

  @create_attrs %{description: "Transfer", amount: -100, date: ~D[2026-03-01]}

  setup do
    {:ok, account1} =
      CashLens.Accounts.create_account(%{
        name: "Account 1",
        bank: "Bank A",
        balance: 0,
        accepts_import: true
      })

    {:ok, account2} =
      CashLens.Accounts.create_account(%{
        name: "Account 2",
        bank: "Bank B",
        balance: 0,
        accepts_import: true
      })

    # Needs a 'transfer' category
    {:ok, _} = CashLens.Categories.create_category(%{name: "Transfer", slug: "transfer"})

    {:ok, origin_tx} =
      Transactions.create_transaction(Map.merge(@create_attrs, %{account_id: account1.id}))

    {:ok, pair_tx} =
      Transactions.create_transaction(
        Map.merge(@create_attrs, %{account_id: account2.id, amount: 100})
      )

    {:ok, account1: account1, account2: account2, origin_tx: origin_tx, pair_tx: pair_tx}
  end

  defmodule HostLive do
    use Phoenix.LiveView
    alias CashLensWeb.TransactionLive.TransferLinkComponent

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         transfer_origin: session["transfer_origin"],
         show_transfer_modal: session["show_transfer_modal"],
         show_quick_transfer_modal: session["show_quick_transfer_modal"] || false,
         accounts: session["accounts"] || [],
         pending_transfers: session["pending_transfers"] || [],
         quick_transfer_form: session["quick_transfer_form"]
       )}
    end

    def handle_event(event, params, socket) do
      send_update(TransferLinkComponent, id: "transfer-component", event: event, params: params)
      {:noreply, socket}
    end

    def handle_info({:transfer_linked, _}, socket), do: {:noreply, socket}
    def handle_info(:close_transfer_modal, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <.live_component
        module={TransferLinkComponent}
        id="transfer-component"
        transfer_origin={@transfer_origin}
        show_transfer_modal={@show_transfer_modal}
        show_quick_transfer_modal={@show_quick_transfer_modal}
        accounts={@accounts}
        pending_transfers={@pending_transfers}
        quick_transfer_form={@quick_transfer_form}
      />
      """
    end
  end

  test "renders transfer modal", %{origin_tx: origin_tx} do
    origin_tx = Transactions.get_transaction!(origin_tx.id) |> CashLens.Repo.preload([:account])

    {:ok, _view, html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "transfer_origin" => origin_tx,
          "show_transfer_modal" => true
        }
      )

    assert html =~ "Link Transfer"
  end

  test "links transfer", %{origin_tx: origin_tx, pair_tx: pair_tx} do
    origin_tx = Transactions.get_transaction!(origin_tx.id) |> CashLens.Repo.preload([:account])
    pair_tx = Transactions.get_transaction!(pair_tx.id) |> CashLens.Repo.preload([:account])

    {:ok, view, _html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "transfer_origin" => origin_tx,
          "show_transfer_modal" => true,
          "pending_transfers" => [pair_tx]
        }
      )

    Ecto.Adapters.SQL.Sandbox.allow(CashLens.Repo, self(), view.pid)

    # Triggering the event on the component
    view |> element("button[phx-value-pair-id='#{pair_tx.id}']") |> render_click()

    updated_origin = Transactions.get_transaction!(origin_tx.id)
    assert updated_origin.transfer_key != nil
  end

  test "open quick transfer modal", %{origin_tx: origin_tx, account2: account2} do
    origin_tx = Transactions.get_transaction!(origin_tx.id) |> CashLens.Repo.preload([:account])

    {:ok, view, _html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "transfer_origin" => origin_tx,
          "show_transfer_modal" => true,
          "accounts" => [account2]
        }
      )

    Ecto.Adapters.SQL.Sandbox.allow(CashLens.Repo, self(), view.pid)

    render_click(view, "open_quick_transfer", %{"myself" => "transfer-component"})

    # Check if the modal exists in the rendered HTML
    assert render(view) =~ "Modal Criar Par da Transferência"
  end

  test "save quick transfer", %{origin_tx: origin_tx, account2: account2} do
    origin_tx = Transactions.get_transaction!(origin_tx.id) |> CashLens.Repo.preload([:account])

    {:ok, view, _html} =
      live_isolated(build_conn(), HostLive,
        session: %{
          "transfer_origin" => origin_tx,
          "show_transfer_modal" => false,
          "show_quick_transfer_modal" => true,
          "accounts" => [account2],
          "quick_transfer_form" =>
            Phoenix.Component.to_form(%{
              "date" => origin_tx.date,
              "amount" => Decimal.mult(origin_tx.amount, -1),
              "description" => origin_tx.description
            })
        }
      )

    render_submit(view, "save_quick_transfer", %{
      "account_id" => account2.id,
      "description" => "Test transfer",
      "date" => "2026-03-01",
      "amount" => "100.00",
      "myself" => "transfer-component"
    })

    # Assert successful linking by the redirect/message
    assert render(view) =~ "Create Transfer Pair"
  end
end
