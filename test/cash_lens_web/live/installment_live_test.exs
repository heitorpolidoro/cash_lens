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

    test "the relief card reports only what ends in the reference month", %{conn: conn} do
      # The whole portfolio starts this month, so nothing is paid off yet and
      # the card has nothing to report — CARTAO B only ends next month.
      {:ok, live, _html} = live(conn, ~p"/installments")

      assert live |> element("#metric-relief-total") |> render() =~ "R$ 0,00"

      breakdown = live |> element("#metric-relief-breakdown") |> render()
      assert breakdown =~ "Nenhum compromisso se encerra"
      refute breakdown =~ "CARTAO B"
    end
  end

  describe "cash-flow relief card" do
    setup do
      # Seven plans whose last parcel falls in the reference month, so the
      # five-row preview has to hide two of them.
      for n <- 1..7 do
        commitment(%{
          description_pattern: "ENCERRA #{n}",
          installments: 2,
          start_date: month_start(-1),
          total_amount: "#{n * 100}.00"
        })
      end

      # A plan still running, to prove the card is not just listing everything.
      commitment(%{description_pattern: "SEGUE", installments: 12, total_amount: "1200.00"})

      :ok
    end

    test "previews five plans and offers the rest behind 'ver mais'", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      # 50 + 100 + ... + 350
      assert live |> element("#metric-relief-total") |> render() =~ "R$ 1.400,00"

      breakdown = live |> element("#metric-relief-breakdown") |> render()
      assert breakdown |> String.split("ENCERRA ") |> length() == 6
      refute breakdown =~ "SEGUE"

      assert live |> element("#metric-relief-more") |> render() =~ "Ver mais 2"
    end

    test "'ver mais' opens a modal with every plan that ends", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")

      refute has_element?(live, "#relief-modal")

      live |> element("#metric-relief-more") |> render_click()

      modal = live |> element("#relief-modal") |> render()
      assert modal |> String.split("ENCERRA ") |> length() == 8
      assert modal =~ "R$ 1.400,00"
      refute modal =~ "SEGUE"

      live |> element("#relief-modal button", "Fechar") |> render_click()
      refute has_element?(live, "#relief-modal")
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

      html = render_click(live, "apply_suggestion", %{"description" => "CONSORCIO PORTO SEGURO"})

      assert html =~ "CONSORCIO PORTO SEGURO"
      assert html =~ "850.00"
      # The first occurrence becomes the start date, so the parcels already
      # paid are assimilated on save.
      assert html =~ "2026-05-10"
      # The term is the one thing the statement cannot know.
      assert html =~ "Falta informar o total de parcelas"
    end

    test "searching narrows the history list", %{conn: conn} do
      acc = account_fixture()

      for description <- ["PRESTACAO DE CRED IMOB", "CONSORCIO PORTO SEGURO"],
          date <- [~D[2026-05-10], ~D[2026-06-10], ~D[2026-07-10]] do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-500.00",
          description: description,
          date: date
        })
      end

      {:ok, live, _html} = live(conn, ~p"/installments")
      html = render_click(live, "open_modal", %{})

      assert html =~ "PRESTACAO DE CRED IMOB"
      assert html =~ "CONSORCIO PORTO SEGURO"

      html = render_change(live, "search_suggestions", %{"suggestion" => %{"q" => "prestacao"}})

      assert html =~ "PRESTACAO DE CRED IMOB"
      refute html =~ "CONSORCIO PORTO SEGURO"

      html = render_change(live, "search_suggestions", %{"suggestion" => %{"q" => "NAO EXISTE"}})
      assert html =~ "Nenhum lançamento recorrente encontrado"
    end

    test "parcelas pagas reaches a contract that began before the statement", %{conn: conn} do
      acc = account_fixture()

      # Only the tail of a 360-month mortgage was ever imported.
      for date <- [~D[2026-07-10], ~D[2026-08-10], ~D[2026-09-10]] do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-3524.55",
          description: "PRESTACAO DE CRED IMOB",
          date: date
        })
      end

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})
      render_click(live, "apply_suggestion", %{"description" => "PRESTACAO DE CRED IMOB"})

      # The suggestion alone can only see the statement: parcel 1 in Jul/2026.
      assert render(live) =~ "2026-07-10"

      html =
        render_change(live, "validate", %{
          "installment_group" => %{
            "commitment_type" => "financing",
            "description_pattern" => "PRESTACAO DE CRED IMOB",
            "installments" => "360",
            "paid_installments" => "81"
          }
        })

      # 81 paid, anchored on the last billed parcel (Sep/2026), puts parcel 1
      # eighty months earlier.
      assert html =~ "2020-01-10"

      summary = live |> element("#term-summary") |> render()
      assert summary =~ "Parcela 81 de 360"
      assert summary =~ "279 restantes"
      assert summary =~ "dez/49"
    end

    test "switching patterns re-anchors the date on the paid count", %{conn: conn} do
      acc = account_fixture()

      for {description, dates} <- [
            {"PRESTACAO DE CRED IMOB", [~D[2026-07-10], ~D[2026-08-10], ~D[2026-09-10]]},
            {"CONSORCIO PORTO SEGURO", [~D[2026-05-15], ~D[2026-06-15], ~D[2026-07-15]]}
          ],
          date <- dates do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-500.00",
          description: description,
          date: date
        })
      end

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})
      render_click(live, "apply_suggestion", %{"description" => "PRESTACAO DE CRED IMOB"})

      render_change(live, "validate", %{
        "installment_group" => %{"installments" => "360", "paid_installments" => "81"}
      })

      assert render(live) =~ "2020-01-10"

      # Picking a different pattern must re-anchor on ITS last parcel (Jul/2026),
      # not fall back to its first occurrence, because 81 is still on the form.
      render_click(live, "clear_suggestion", %{})
      html = render_click(live, "apply_suggestion", %{"description" => "CONSORCIO PORTO SEGURO"})

      assert html =~ "2019-11-15"
      refute html =~ "2026-05-15"
    end

    test "a hand-typed start date survives further edits", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})

      render_change(live, "validate", %{
        "installment_group" => %{"installments" => "360", "paid_installments" => "81"}
      })

      html =
        render_change(live, "validate", %{
          "installment_group" => %{
            "installments" => "360",
            "paid_installments" => "81",
            "start_date" => "2019-06-15"
          }
        })

      # paid_installments did not change, so it must not overwrite the date.
      assert html =~ "2019-06-15"
    end

    test "'trocar' puts the picker back", %{conn: conn} do
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
      render_click(live, "open_modal", %{})

      render_click(live, "apply_suggestion", %{"description" => "CONSORCIO PORTO SEGURO"})
      assert has_element?(live, "#quick-fill-applied")
      refute has_element?(live, "#quick-fill-results")

      render_click(live, "clear_suggestion", %{})
      refute has_element?(live, "#quick-fill-applied")
      assert has_element?(live, "#quick-fill-results")
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

      html = render_click(live, "apply_suggestion", %{"description" => ""})
      refute html =~ "DESCONHECIDO"

      html = render_click(live, "apply_suggestion", %{"description" => "DESCONHECIDO"})
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

    test "the delete button asks for confirmation and says what survives", %{conn: conn} do
      acc = account_fixture()
      group = commitment(%{description_pattern: "COM PARCELAS"})
      vazio = commitment(%{description_pattern: "SEM PARCELAS"})

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-100.00",
          description: "COM PARCELAS 1"
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [installment_group_id: group.id, installment_number: 1]
      )

      {:ok, live, _html} = live(conn, ~p"/installments")

      # No browser alert: nothing confirms until the app's own modal is opened.
      refute render(live) =~ "data-confirm"
      refute has_element?(live, "#delete-modal")

      render_click(live, "ask_delete", %{"id" => group.id})
      message = live |> element("#delete-modal-message") |> render()
      assert message =~ "Excluir &quot;COM PARCELAS&quot;?"
      assert message =~ "O lançamento vinculado volta a ser uma transação solta"

      # Cancelling keeps the commitment.
      render_click(live, "cancel_delete", %{})
      refute has_element?(live, "#delete-modal")
      assert length(Installments.list_installment_groups()) == 2

      render_click(live, "ask_delete", %{"id" => vazio.id})

      assert live |> element("#delete-modal-message") |> render() =~
               "Nenhum lançamento está vinculado"
    end

    test "editing shows how many parcels are already paid", %{conn: conn} do
      # Parcel 1 fell 81 months ago, so parcels 1..81 are paid and this month
      # bills 82 — leaving 279 of the 360.
      group =
        commitment(%{
          description_pattern: "FINANCIAMENTO LONGO",
          commitment_type: "financing",
          installments: 360,
          start_date: month_start(-81)
        })

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "edit", %{"id" => group.id})

      assert live
             |> element("#installment_group_paid_installments")
             |> render() =~ ~s(value="81")

      # Re-opening must not move the stored start date.
      assert live |> element("#term-summary") |> render() =~ "279 restantes"
    end

    test "the total follows the term through every keystroke", %{conn: conn} do
      acc = account_fixture()

      for date <- [~D[2026-07-21], ~D[2026-08-21], ~D[2026-09-21]] do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-1471.52",
          description: "BANCO GM SA",
          date: date
        })
      end

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "open_modal", %{})
      render_click(live, "apply_suggestion", %{"description" => "BANCO GM SA"})

      # Typing "60" arrives as "6" and then "60", through the real form, so every
      # rendered input is sent back — including a total the form itself derived.
      for term <- ["6", "60"] do
        live
        |> form("#commitment-form",
          installment_group: %{
            "description_pattern" => "BANCO GM SA",
            "installment_amount" => "1471.52",
            "installments" => term,
            "start_date" => "2022-11-21"
          }
        )
        |> render_change()
      end

      live
      |> form("#commitment-form",
        installment_group: %{
          "description_pattern" => "BANCO GM SA",
          "installment_amount" => "1471.52",
          "installments" => "60",
          "start_date" => "2022-11-21"
        }
      )
      |> render_submit()

      assert [group] = Installments.list_installment_groups()
      assert group.installments == 60
      assert Decimal.equal?(Installments.parcel_value(group), Decimal.new("1471.52"))
    end

    test "the trash button opens the modal instead of deleting", %{conn: conn} do
      group = commitment(%{description_pattern: "NAO APAGUE AINDA"})

      {:ok, live, _html} = live(conn, ~p"/installments")

      live |> element("#delete-#{group.id}") |> render_click()

      assert has_element?(live, "#delete-modal")
      assert length(Installments.list_installment_groups()) == 1
    end

    test "confirming in the modal deletes and closes it", %{conn: conn} do
      group = commitment(%{description_pattern: "PARA EXCLUIR"})

      {:ok, live, _html} = live(conn, ~p"/installments")
      render_click(live, "ask_delete", %{"id" => group.id})

      live |> element("#delete-modal-confirm") |> render_click()

      refute has_element?(live, "#delete-modal")
      assert Installments.list_installment_groups() == []
    end

    test "the confirmation pluralises for several parcels", %{conn: conn} do
      acc = account_fixture()
      group = commitment(%{description_pattern: "TRES PARCELAS", installments: 3})

      for n <- 1..3 do
        tx =
          transaction_fixture(%{
            account_id: acc.id,
            amount: "-100.00",
            description: "TRES PARCELAS #{n}"
          })

        Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
          set: [installment_group_id: group.id, installment_number: n]
        )
      end

      {:ok, live, _html} = live(conn, ~p"/installments")

      render_click(live, "ask_delete", %{"id" => group.id})

      assert live |> element("#delete-modal-message") |> render() =~
               "Os 3 lançamentos vinculados voltam a ser transações soltas"
    end

    test "deleting a commitment with parcels does not crash the view", %{conn: conn} do
      acc = account_fixture()
      group = commitment(%{description_pattern: "COM PARCELAS"})

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-100.00",
          description: "COM PARCELAS 1"
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [installment_group_id: group.id, installment_number: 1]
      )

      {:ok, live, _html} = live(conn, ~p"/installments")
      assert render(live) =~ "COM PARCELAS"

      html = render_click(live, "delete", %{"id" => group.id})

      refute html =~ "COM PARCELAS"
      assert Installments.list_installment_groups() == []
    end

    test "bands the table by payoff month, not by row", %{conn: conn} do
      # Two plans end in m0+1 and two in m0+2, so the shading must flip once
      # between the pairs — never inside one.
      commitment(%{description_pattern: "PAR UM A", installments: 2})
      commitment(%{description_pattern: "PAR UM B", installments: 2})
      commitment(%{description_pattern: "PAR DOIS A", installments: 3})
      commitment(%{description_pattern: "PAR DOIS B", installments: 3})

      {:ok, live, _html} = live(conn, ~p"/installments")

      shaded =
        live
        |> render()
        |> then(&Regex.scan(~r/<tr class="([^"]*)"[^>]*>.*?(PAR \w+ \w)/s, &1))
        |> Map.new(fn [_, classes, name] -> {name, String.contains?(classes, "bg-base-200")} end)

      # Without this the three assertions below pass vacuously on nil == nil.
      assert map_size(shaded) == 4

      assert shaded["PAR UM A"] == shaded["PAR UM B"]
      assert shaded["PAR DOIS A"] == shaded["PAR DOIS B"]
      assert shaded["PAR UM A"] != shaded["PAR DOIS A"]
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
