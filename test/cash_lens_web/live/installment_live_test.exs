defmodule CashLensWeb.InstallmentLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  defp month_start(offset) do
    today = Date.utc_today()
    Installments.add_months(Date.new!(today.year, today.month, 1), offset)
  end

  defp commitment(attrs) do
    {:ok, group} =
      Installments.create_installment_group(
        Map.merge(
          %{
            description_pattern: "G",
            installments: 3,
            start_date: month_start(0),
            total_amount: "300.00"
          },
          attrs
        )
      )

    group
  end

  defp portfolio do
    card_a =
      commitment(%{description_pattern: "CARTAO A", installments: 3, total_amount: "300.00"})

    card_b =
      commitment(%{description_pattern: "CARTAO B", installments: 2, total_amount: "200.00"})

    fin =
      commitment(%{
        description_pattern: "FINANCIAMENTO CAIXA",
        commitment_type: "financing",
        institution: "Caixa",
        interest_rate: "8.5",
        installments: 10,
        total_amount: "10000.00"
      })

    cons =
      commitment(%{
        description_pattern: "CONSORCIO PORTO",
        commitment_type: "consorcio",
        institution: "Porto Seguro",
        credit_letter_amount: "80000.00",
        installments: 5,
        total_amount: "5000.00"
      })

    %{card_a: card_a, card_b: card_b, fin: fin, cons: cons}
  end

  test "renders the commitments screen with no groups", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/installments")
    assert html =~ "Compromissos a Prazo"
    assert html =~ "Nenhum compromisso encontrado"
  end

  describe "global metric cards" do
    setup do
      portfolio()
    end

    test "breaks the monthly commitment down by type with counts", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      assert live |> element("#metric-month-total") |> render() =~ "R$ 2.200,00"

      breakdown = live |> element("#metric-month-breakdown") |> render()
      assert breakdown =~ "Parcelamentos Cartão (2 compras)"
      assert breakdown =~ "R$ 200,00"
      assert breakdown =~ "Financiamentos (1 contrato)"
      assert breakdown =~ "Consórcios (1 cota)"
      assert breakdown =~ "R$ 1.000,00"
    end

    test "shows the consolidated outstanding balance", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      assert live |> element("#metric-remaining-total") |> render() =~ "R$ 15.500,00"

      breakdown = live |> element("#metric-remaining-breakdown") |> render()
      assert breakdown =~ "R$ 500,00"
      assert breakdown =~ "R$ 10.000,00"
      assert breakdown =~ "R$ 5.000,00"
    end

    test "shows the 90-day cash-flow relief with the plans that end", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      assert live |> element("#metric-relief-total") |> render() =~ "R$ 200,00"

      breakdown = live |> element("#metric-relief-breakdown") |> render()
      assert breakdown =~ "CARTAO A"
      assert breakdown =~ "CARTAO B"
      refute breakdown =~ "FINANCIAMENTO CAIXA"
    end
  end

  describe "stacked monthly projection ribbon" do
    setup do
      portfolio()
    end

    test "renders one cell per month with the total and the per-type split", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      cell = live |> element("#projection-#{Date.to_iso8601(month_start(0))}") |> render()

      assert cell =~ "R$ 2.200,00"
      assert cell =~ "R$ 200,00"
      assert cell =~ "R$ 1.000,00"
    end

    test "the stacked bars are proportional and fill the whole bar", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      for offset <- 0..3 do
        cell = live |> element("#projection-#{Date.to_iso8601(month_start(offset))}") |> render()

        widths =
          Regex.scan(~r/width:\s*([0-9.]+)%/, cell)
          |> Enum.map(fn [_, w] -> String.to_float(w) end)

        assert length(widths) == 3, "expected three stacked segments for offset #{offset}"
        assert_in_delta Enum.sum(widths), 100.0, 0.5
      end
    end

    test "the card share shrinks as card purchases are paid off", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      # Month 0 and 1: both card purchases due (R$ 200). Month 2: only CARTAO A.
      assert live |> element("#projection-#{Date.to_iso8601(month_start(2))}") |> render() =~
               "R$ 2.100,00"

      # Month 3: no card purchases left, only financing + consórcio.
      assert live |> element("#projection-#{Date.to_iso8601(month_start(3))}") |> render() =~
               "R$ 2.000,00"
    end
  end

  describe "type and status tabs" do
    setup do
      portfolio()
    end

    test "all tabs are rendered with their active counts", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      assert has_element?(live, "#type-tab-all")
      assert live |> element("#type-tab-credit_card") |> render() =~ "Cartão de Crédito"
      assert live |> element("#type-tab-financing") |> render() =~ "Financiamentos"
      assert live |> element("#type-tab-consorcio") |> render() =~ "Consórcios"
      assert live |> element("#badge-count-credit_card") |> render() =~ "2"
      assert live |> element("#badge-count-financing") |> render() =~ "1"
      assert live |> element("#badge-count-consorcio") |> render() =~ "1"
    end

    test "filtering by financing keeps only financing commitments", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      live |> element("#type-tab-financing") |> render_click()
      listing = live |> element("#commitments-table") |> render()

      assert listing =~ "FINANCIAMENTO CAIXA"
      refute listing =~ "CARTAO A"
      refute listing =~ "CONSORCIO PORTO"
    end

    test "filtering by consorcio keeps only consórcios", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      live |> element("#type-tab-consorcio") |> render_click()
      listing = live |> element("#commitments-table") |> render()

      assert listing =~ "CONSORCIO PORTO"
      refute listing =~ "FINANCIAMENTO CAIXA"
    end

    test "filtering by credit card keeps only card purchases", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      live |> element("#type-tab-credit_card") |> render_click()
      listing = live |> element("#commitments-table") |> render()

      assert listing =~ "CARTAO A"
      assert listing =~ "CARTAO B"
      refute listing =~ "FINANCIAMENTO CAIXA"
    end

    test "the concluded tab lists finished plans and the active tab hides them", %{conn: conn} do
      commitment(%{
        description_pattern: "PLANO QUITADO",
        installments: 2,
        start_date: month_start(-10),
        total_amount: "200.00"
      })

      {:ok, live, _html} = live(conn, ~p"/installments")
      listing = live |> element("#commitments-table") |> render()
      refute listing =~ "PLANO QUITADO"

      live |> element("#status-tab-completed") |> render_click()
      listing = live |> element("#commitments-table") |> render()
      assert listing =~ "PLANO QUITADO"
      refute listing =~ "CARTAO A"

      live |> element("#status-tab-active") |> render_click()
      listing = live |> element("#commitments-table") |> render()
      assert listing =~ "CARTAO A"
      refute listing =~ "PLANO QUITADO"
    end

    test "the all-status tab lists both active and finished plans", %{conn: conn} do
      commitment(%{
        description_pattern: "PLANO ANTIGO",
        installments: 2,
        start_date: month_start(-10),
        total_amount: "200.00"
      })

      {:ok, live, _html} = live(conn, ~p"/installments")

      live |> element("#status-tab-all") |> render_click()
      listing = live |> element("#commitments-table") |> render()

      assert listing =~ "PLANO ANTIGO"
      assert listing =~ "CARTAO A"
    end

    test "searching narrows the listing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      render_change(live, "search", %{"search" => %{"q" => "consorcio"}})
      listing = live |> element("#commitments-table") |> render()

      assert listing =~ "CONSORCIO PORTO"
      refute listing =~ "CARTAO A"
    end
  end

  describe "new-commitment modal" do
    test "opens with the credit-card form and switches to financing fields", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      html = render_click(live, "open_modal", %{})
      assert html =~ "Novo Compromisso"
      assert has_element?(live, "#fields-credit-card")
      refute has_element?(live, "#field-interest-rate")

      html = live |> element("#modal-type-financing") |> render_click()
      assert html =~ "Instituição"
      assert has_element?(live, "#field-interest-rate")
      refute has_element?(live, "#field-credit-letter")

      live |> element("#modal-type-consorcio") |> render_click()
      assert has_element?(live, "#field-credit-letter")
      assert has_element?(live, "#field-contemplation")
    end

    test "creates a financing commitment with its specific fields", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})

      render_submit(live, "save", %{
        "installment_group" => %{
          "commitment_type" => "financing",
          "description_pattern" => "FINANC HAB CAIXA",
          "institution" => "Caixa Econômica",
          "interest_rate" => "8.5",
          "installments" => "360",
          "total_amount" => "280000.00",
          "start_date" => Date.to_string(month_start(0))
        }
      })

      assert render(live) =~ "Compromisso criado"

      group =
        Enum.find(
          Installments.list_installment_groups(),
          &(&1.description_pattern == "FINANC HAB CAIXA")
        )

      assert group.commitment_type == "financing"
      assert group.institution == "Caixa Econômica"
      assert Decimal.equal?(group.interest_rate, Decimal.new("8.5"))
    end

    test "creates a consórcio with credit letter and contemplation", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})

      render_submit(live, "save", %{
        "installment_group" => %{
          "commitment_type" => "consorcio",
          "description_pattern" => "CONSORCIO PORTO SEGURO",
          "institution" => "Porto Seguro",
          "credit_letter_amount" => "80000.00",
          "is_contemplated" => "true",
          "installments" => "120",
          "total_amount" => "102000.00",
          "start_date" => Date.to_string(month_start(0))
        }
      })

      group =
        Enum.find(
          Installments.list_installment_groups(),
          &(&1.description_pattern == "CONSORCIO PORTO SEGURO")
        )

      assert group.commitment_type == "consorcio"
      assert group.is_contemplated
      assert Decimal.equal?(group.credit_letter_amount, Decimal.new("80000.00"))
    end

    test "auto-fills the form from a recurring statement pattern", %{conn: conn} do
      acc = account_fixture()

      for date <- [~D[2026-05-10], ~D[2026-06-10], ~D[2026-07-10]] do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-850.00",
          description: "CONSORCIO PORTO SEGURO",
          date: date
        })
      end

      {:ok, live, _html} = live(conn, ~p"/installments")
      html = render_click(live, "open_modal", %{})

      assert html =~ "Vincular por Histórico do Extrato"
      assert html =~ "CONSORCIO PORTO SEGURO"
      assert html =~ "3"

      html =
        render_change(live, "apply_suggestion", %{
          "suggestion" => %{"description" => "CONSORCIO PORTO SEGURO"}
        })

      assert html =~ "CONSORCIO PORTO SEGURO"
      assert html =~ "850.00"
    end

    test "save with invalid data re-renders the form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})

      render_submit(live, "save", %{
        "installment_group" => %{
          "description_pattern" => "",
          "installments" => "",
          "start_date" => ""
        }
      })

      assert Installments.list_installment_groups() == []
    end

    test "close_modal hides the form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      render_click(live, "open_modal", %{})
      assert has_element?(live, "#fields-credit-card")

      render_click(live, "close_modal", %{})
      refute has_element?(live, "#fields-credit-card")
    end

    test "validate keeps the typed values while switching the commitment type", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})

      render_change(live, "validate", %{
        "installment_group" => %{
          "commitment_type" => "credit_card",
          "description_pattern" => "RASCUNHO",
          "installments" => "6"
        }
      })

      html = live |> element("#modal-type-financing") |> render_click()
      assert html =~ "RASCUNHO"
      assert has_element?(live, "#field-interest-rate")
    end

    test "apply_suggestion ignores a blank or unknown selection", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})

      html = render_change(live, "apply_suggestion", %{"suggestion" => %{"description" => ""}})
      refute html =~ "DESCONHECIDO"

      html =
        render_change(live, "apply_suggestion", %{
          "suggestion" => %{"description" => "DESCONHECIDO"}
        })

      refute html =~ "DESCONHECIDO"
    end

    test "editing an existing commitment saves the changes", %{conn: conn} do
      group = commitment(%{description_pattern: "ANTIGO"})

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "edit", %{"id" => group.id})

      render_submit(live, "save", %{
        "installment_group" => %{
          "commitment_type" => "financing",
          "description_pattern" => "NOVO NOME",
          "installments" => "3",
          "total_amount" => "300.00",
          "start_date" => Date.to_string(month_start(0))
        }
      })

      assert render(live) =~ "Compromisso atualizado!"
      assert Installments.get_installment_group!(group.id).description_pattern == "NOVO NOME"
    end

    test "editing with invalid data re-renders the form", %{conn: conn} do
      group = commitment(%{description_pattern: "IMUTAVEL"})

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "edit", %{"id" => group.id})

      render_submit(live, "save", %{
        "installment_group" => %{"description_pattern" => "", "installments" => "1"}
      })

      assert Installments.get_installment_group!(group.id).description_pattern == "IMUTAVEL"
    end

    test "edit loads an existing commitment into the modal", %{conn: conn} do
      group = commitment(%{description_pattern: "EDITAVEL"})

      {:ok, live, _html} = live(conn, ~p"/installments")
      html = render_click(live, "edit", %{"id" => group.id})

      assert html =~ "Editar Compromisso"
      assert html =~ "EDITAVEL"
    end
  end

  describe "listing" do
    test "shows type badges, outstanding balance and payoff month", %{conn: conn} do
      commitment(%{
        description_pattern: "FINANC AUTO",
        commitment_type: "financing",
        installments: 10,
        start_date: ~D[2026-01-15],
        total_amount: "10000.00"
      })

      {:ok, _live, html} = live(conn, ~p"/installments")

      assert html =~ "FINANC AUTO"
      assert html =~ "Financiamento"
      # 2026-01 + 9 months = 2026-10 -> "out/26"
      assert html =~ "out/26"
    end

    test "expands a commitment row to list its parcels", %{conn: conn} do
      group = commitment(%{description_pattern: "EXPAND ME", installments: 2})
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-100.00",
          description: "EXPAND ME parcela 1"
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [installment_group_id: group.id, installment_number: 1]
      )

      {:ok, live, html} = live(conn, ~p"/installments")
      refute html =~ "EXPAND ME parcela 1"

      html = render_click(live, "toggle_expand", %{"id" => group.id})
      assert html =~ "EXPAND ME parcela 1"

      html = render_click(live, "toggle_expand", %{"id" => group.id})
      refute html =~ "EXPAND ME parcela 1"
    end

    test "delete removes a commitment", %{conn: conn} do
      group = commitment(%{description_pattern: "DEL"})

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "delete", %{"id" => group.id})

      assert Installments.list_installment_groups() == []
    end
  end

  test "the heavy statement scan is no longer offered on this screen", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/installments")

    refute html =~ "Detectar Parcelamentos"
    refute html =~ "detect_installments"
  end
end
