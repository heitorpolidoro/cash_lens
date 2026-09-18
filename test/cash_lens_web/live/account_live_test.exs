defmodule CashLensWeb.AccountLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures

  @create_attrs %{
    name: "some name",
    balance: "120.5",
    color: "#820ad1",
    bank: "some bank",
    icon: "https://example.com/icon.png"
  }
  @update_attrs %{
    name: "some updated name",
    balance: "456.7",
    color: "#ec7000",
    bank: "some updated bank",
    icon: "https://example.com/updated.png"
  }
  @invalid_attrs %{name: nil, balance: nil, color: nil, bank: nil, icon: nil}

  defp create_account(_) do
    account = account_fixture()

    %{account: account}
  end

  # An account whose latest calculated balance (540.25) differs from its
  # initial balance (100.00), so the "Saldo Atual" field has something of its
  # own to show.
  defp with_calculated_balance do
    account = account_fixture(%{balance: "100.00"})

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: account.id,
      amount: "440.25",
      date: Date.utc_today()
    })

    CashLens.Accounting.rebuild_account_balances(account.id)

    account
  end

  describe "Index sections" do
    test "lists bank accounts and credit cards in separate sections", %{conn: conn} do
      bank = account_fixture(%{name: "Conta Corrente", is_credit_card: false})
      card = account_fixture(%{name: "Cartao Preto", is_credit_card: true})

      {:ok, live, html} = live(conn, ~p"/accounts")

      assert html =~ "Contas Bancárias"
      assert html =~ "Cartões de Crédito"

      assert has_element?(live, "#bank-accounts #account-#{bank.id}", "Conta Corrente")
      assert has_element?(live, "#credit-cards #account-#{card.id}", "Cartao Preto")

      refute has_element?(live, "#bank-accounts #account-#{card.id}")
      refute has_element?(live, "#credit-cards #account-#{bank.id}")
    end

    test "renders the consolidated bank accounts total balance", %{conn: conn} do
      account_fixture(%{name: "A", balance: "1000.00", is_credit_card: false})
      account_fixture(%{name: "B", balance: "250.50", is_credit_card: false})
      account_fixture(%{name: "C", balance: "999.99", is_credit_card: true})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      total = live |> element("#bank-accounts-total") |> render()

      assert total =~ "1.250,50"
      refute total =~ "999,99"
    end

    test "shows the statement shortcut for bank accounts and cards", %{conn: conn} do
      bank = account_fixture(%{name: "Banco", is_credit_card: false})
      card = account_fixture(%{name: "Cartao", is_credit_card: true})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      assert live
             |> element(~s(#account-#{bank.id} a[href*="/transactions?account_id=#{bank.id}"]))
             |> has_element?()

      assert live
             |> element(~s(#account-#{card.id} a[href*="/statements?account_id=#{card.id}"]))
             |> has_element?()
    end

    test "shows card rules: closing day, due day and configured parser", %{conn: conn} do
      card =
        account_fixture(%{
          name: "Cartao Regras",
          is_credit_card: true,
          closing_day: 13,
          due_day: 20,
          parser_type: "bradesco_cartao_pdf"
        })

      {:ok, live, _html} = live(conn, ~p"/accounts")

      card_html = live |> element("#account-#{card.id}") |> render()

      assert card_html =~ "13"
      assert card_html =~ "20"
      assert card_html =~ "Bradesco Cartão (PDF)"
    end

    test "shows the configured parser on bank account cards", %{conn: conn} do
      bank = account_fixture(%{name: "Banco Parser", parser_type: "bb_csv"})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      assert live |> element("#account-#{bank.id}") |> render() =~ "Banco do Brasil (CSV)"
    end

    test "renders initials when the account has no icon", %{conn: conn} do
      account = account_fixture(%{name: "No Icon Account", bank: "TestBank", icon: nil})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      assert live |> element("#account-#{account.id}") |> render() =~ "Te"
    end
  end

  describe "Closed accounts" do
    test "hides closed accounts until the toggle is enabled", %{conn: conn} do
      closed = account_fixture(%{name: "Conta Encerrada", is_closed: true})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      refute has_element?(live, "#account-#{closed.id}")

      html =
        live
        |> form("#show-closed-form")
        |> render_change(%{"show_closed" => "true"})

      assert html =~ "Conta Encerrada"
      assert html =~ "Encerrada"
      assert has_element?(live, "#account-#{closed.id}")

      live |> form("#show-closed-form") |> render_change(%{"show_closed" => "false"})
      refute has_element?(live, "#account-#{closed.id}")
    end

    test "archives an active account", %{conn: conn} do
      account = account_fixture(%{name: "Para Arquivar"})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      live
      |> element(~s(#account-#{account.id} button[phx-click="toggle_archive"]))
      |> render_click()

      assert CashLens.Accounts.get_account!(account.id).is_closed
      refute has_element?(live, "#account-#{account.id}")
    end

    test "reactivates a closed account", %{conn: conn} do
      account = account_fixture(%{name: "Para Reativar", is_closed: true})

      {:ok, live, _html} = live(conn, ~p"/accounts")
      live |> form("#show-closed-form") |> render_change(%{"show_closed" => "true"})

      live
      |> element(~s(#account-#{account.id} button[phx-click="toggle_archive"]))
      |> render_click()

      refute CashLens.Accounts.get_account!(account.id).is_closed
      assert has_element?(live, "#account-#{account.id}")
    end
  end

  describe "Create modal" do
    test "opens the new account modal from the index", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      refute has_element?(live, "#account-form")

      html = live |> element("a", "Nova Conta") |> render_click()

      assert_patch(live, ~p"/accounts/new")
      assert html =~ "Nova Conta"
      assert has_element?(live, "#account-form")
    end

    test "saves a new account and closes the modal", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/accounts/new")

      assert live
             |> form("#account-form", account: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      live |> form("#account-form", account: @create_attrs) |> render_submit()

      assert_patch(live, ~p"/accounts")

      html = render(live)
      assert html =~ "Conta criada com sucesso"
      assert html =~ "some name"
      refute has_element?(live, "#account-form")
    end

    test "keeps the modal open when the submitted data is invalid", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/accounts/new")

      html = live |> form("#account-form", account: %{name: nil}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(live, "#account-form")
    end

    test "closes the modal without saving", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/accounts/new")

      live |> element("#account-form-modal-close") |> render_click()

      assert_patch(live, ~p"/accounts")
      refute has_element?(live, "#account-form")
    end
  end

  describe "Edit modal" do
    setup [:create_account]

    test "opens from the account card", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      live
      |> element(~s(#account-#{account.id} a[href="/accounts/#{account.id}/edit"]))
      |> render_click()

      assert_patch(live, ~p"/accounts/#{account}/edit")
      assert has_element?(live, "#account-form")
      assert render(live) =~ "Editar Conta"
    end

    test "renders the eight parser options with the current one preselected", %{conn: conn} do
      account = account_fixture(%{parser_type: "bb_csv"})

      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      html = live |> element("#account-form select[name='account[parser_type]']") |> render()

      assert html =~ "Selecione um extrator"

      for {value, label} <- [
            {"bradesco_csv", "Bradesco (CSV)"},
            {"bradesco_cartao_pdf", "Bradesco Cartão (PDF)"},
            {"mercadopago_cartao_pdf", "Mercado Pago Cartão (PDF)"},
            {"bb_csv", "Banco do Brasil (CSV)"},
            {"mercado_pago_csv", "Mercado Pago (CSV)"},
            {"ourocard_ofx", "Ourocard (OFX)"},
            {"sem_parar_pdf", "Sem Parar (PDF)"},
            {"standard_ofx", "OFX Padrão"}
          ] do
        assert html =~ ~s(value="#{value}")
        assert html =~ label
      end

      assert html =~ ~s(<option selected="" value="bb_csv">)
    end

    test "renders the icon url input and its circular preview", %{conn: conn} do
      account = account_fixture(%{icon: "https://example.com/logo.png"})

      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      assert has_element?(
               live,
               ~s(#account-form input[name="account[icon]"][value="https://example.com/logo.png"])
             )

      preview = live |> element("#account-icon-preview") |> render()
      assert preview =~ "rounded-full"
      assert preview =~ ~s(src="https://example.com/logo.png")
      refute preview =~ "hero-photo"
    end

    test "shows the placeholder preview when the icon is empty", %{conn: conn} do
      account = account_fixture(%{icon: nil})

      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      assert live |> element("#account-icon-preview") |> render() =~ "hero-photo"

      live
      |> form("#account-form", account: Map.put(@update_attrs, :icon, "https://cdn/x.png"))
      |> render_change()

      assert live |> element("#account-icon-preview") |> render() =~ ~s(src="https://cdn/x.png")
    end

    test "persists the chosen parser and icon", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      live
      |> form("#account-form",
        account:
          Map.merge(@update_attrs, %{
            parser_type: "standard_ofx",
            icon: "https://example.com/new-icon.png"
          })
      )
      |> render_submit()

      assert_patch(live, ~p"/accounts")

      reloaded = CashLens.Accounts.get_account!(account.id)
      assert reloaded.parser_type == "standard_ofx"
      assert reloaded.icon == "https://example.com/new-icon.png"
      assert render(live) =~ "Conta atualizada com sucesso"
    end

    test "offers institutional color presets that fill the color field", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      assert has_element?(live, ~s(#account-form button[phx-click="pick_color"]))

      live
      |> element(~s(#account-form button[phx-value-color="#820ad1"]))
      |> render_click()

      assert has_element?(live, ~s(#account-form input[name="account[color]"][value="#820ad1"]))
    end

    test "prefills the current balance from the latest calculated balance", %{conn: conn} do
      account = with_calculated_balance()

      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      assert has_element?(
               live,
               ~s(#account-form input[name="account[current_balance]"][value="540.25"])
             )
    end

    test "adjusting the current balance shifts the initial balance by the difference", %{
      conn: conn
    } do
      account = with_calculated_balance()

      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      live
      |> form("#account-form",
        account: %{
          name: account.name,
          bank: account.bank,
          balance: "100.00",
          current_balance: "560.25"
        }
      )
      |> render_submit()

      assert_patch(live, ~p"/accounts")

      assert Decimal.equal?(
               CashLens.Accounts.get_account!(account.id).balance,
               Decimal.new("120.00")
             )
    end

    test "closing the account from the modal archives it", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      # The initial balance is submitted unchanged: only `is_closed` moves, so
      # the archived account still gets its balances rebuilt.
      live
      |> form("#account-form",
        account: %{
          name: account.name,
          bank: account.bank,
          balance: account.balance,
          is_closed: true
        }
      )
      |> render_submit()

      assert_patch(live, ~p"/accounts")
      assert CashLens.Accounts.get_account!(account.id).is_closed
      refute has_element?(live, "#account-#{account.id}")
    end

    test "shows an error when submitting invalid data", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      html = live |> form("#account-form", account: %{name: nil}) |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "Credit card billing cycle" do
    test "credit-card account modal shows cycle fields and estimate button", %{conn: conn} do
      account = account_fixture(%{is_credit_card: true})
      {:ok, _live, html} = live(conn, ~p"/accounts/#{account}/edit")

      assert html =~ "Dia de fechamento"
      assert html =~ "Dia de vencimento"
      assert html =~ "Estimar do histórico"
    end

    test "non-credit-card account modal hides cycle fields", %{conn: conn} do
      account = account_fixture(%{is_credit_card: false})
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      form_html = live |> element("#account-form") |> render()
      refute form_html =~ "Dia de fechamento"
      refute form_html =~ "Estimar do histórico"
    end

    test "estimate_cycle fills fields from history without saving", %{conn: conn} do
      account = account_fixture(%{is_credit_card: true})

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: account,
        due_date: ~D[2026-06-15]
      })

      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit")

      live |> element("button", "Estimar do histórico") |> render_click()

      form_html = live |> element("#account-form") |> render()
      assert form_html =~ ~s(value="15")
      assert form_html =~ ~s(value="8")

      reloaded = CashLens.Accounts.get_account!(account.id)
      assert reloaded.closing_day == nil
      assert reloaded.due_day == nil
    end
  end

  describe "Delete" do
    setup [:create_account]

    test "cancels delete modal via close_modal", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      live
      |> element(~s(#account-#{account.id} button[phx-click="confirm_delete"]))
      |> render_click()

      assert render(live) =~ "Excluir Conta?"

      render_click(live, "close_modal", %{})
      refute render(live) =~ "Excluir Conta?"
    end

    test "deletes the account", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/accounts")

      live
      |> element(~s(#account-#{account.id} button[phx-click="confirm_delete"]))
      |> render_click()

      live |> element("button", "Sim, Excluir") |> render_click()

      refute has_element?(live, "#account-#{account.id}")
    end
  end

  describe "return_to" do
    setup [:create_account]

    test "navigates to /transactions after save when return_to=transactions", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit?return_to=transactions")

      live |> form("#account-form", account: @update_attrs) |> render_submit()

      assert flash = assert_redirect(live, ~p"/transactions")
      assert flash["success"] == "Conta atualizada com sucesso"
    end

    test "navigates back to the account page when return_to=show", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/accounts/#{account}/edit?return_to=show")

      live |> form("#account-form", account: @update_attrs) |> render_submit()

      assert flash = assert_redirect(live, ~p"/accounts/#{account}")
      assert flash["success"] == "Conta atualizada com sucesso"
    end
  end

  describe "Update balance with income" do
    test "opens and cancels the update balance modal", %{conn: conn} do
      account = account_fixture(%{is_credit_card: false})

      {:ok, live, _html} = live(conn, ~p"/accounts")

      live
      |> element(~s(#account-#{account.id} button[phx-click="open_update_balance_modal"]))
      |> render_click()

      assert render(live) =~ "Atualizar com Rendimentos"

      render_click(live, "close_update_balance_modal", %{})
      refute render(live) =~ "Atualizar com Rendimentos"
    end
  end

  describe "Show" do
    setup [:create_account]

    test "displays account", %{conn: conn, account: account} do
      {:ok, _show_live, html} = live(conn, ~p"/accounts/#{account}")

      assert html =~ "Detalhes da Conta"
      assert html =~ account.name
    end

    test "opens the edit modal over the index from the show page", %{
      conn: conn,
      account: account
    } do
      {:ok, show_live, _html} = live(conn, ~p"/accounts/#{account}")

      assert {:ok, live, _} =
               show_live
               |> element("a", "Editar conta")
               |> render_click()
               |> follow_redirect(conn, ~p"/accounts/#{account}/edit?return_to=show")

      assert has_element?(live, "#account-form")
    end
  end
end
