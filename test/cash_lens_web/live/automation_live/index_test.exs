defmodule CashLensWeb.AutomationLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  defp user, do: CashLens.Repo.get!(CashLens.Users.User, CashLens.Repo.current_user_id())

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Transactions

  setup do
    source = account_fixture(%{name: "Conta Origem"})
    destination = account_fixture(%{name: "Conta Destino"})
    %{source: source, destination: destination}
  end

  describe "unified automation center" do
    test "renders the page title, both tabs and the transfers section", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/automation")

      assert html =~ "Central de Automações &amp; Regras"
      assert html =~ "Regras de Transferência"
      assert html =~ "Exclusão de Ruído / Regex"
      assert html =~ "Regras de Pareamento e Criação de Espelho"
    end

    test "renders no count or quantity indicator at all", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      transfer_rule_fixture(%{
        label: "Aporte Reserva",
        description_patterns: ["TED RESERVA"],
        source_account_id: source.id,
        destination_account_id: destination.id
      })

      {:ok, live, _html} = live(conn, ~p"/automation")

      for html <- [render(live), render_click(element(live, "#tab-exclusions"))] do
        refute html =~ ~r/\(\d+\)/

        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s([data-role="metric-card"]))
               |> Enum.to_list() == []
      end
    end

    test "legacy paths redirect to the matching tab", %{conn: conn} do
      assert conn |> get(~p"/admin/transfer_rules") |> redirected_to() ==
               "/automation?tab=transfers"

      assert conn |> get(~p"/admin/exclusion_rules") |> redirected_to() ==
               "/automation?tab=exclusions"
    end

    test "the tab query param selects the tab on mount", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/automation?tab=exclusions")

      assert html =~ "Padrões Regex para Ignorar Ruídos de Extrato"
      refute html =~ "Regras de Pareamento e Criação de Espelho"
    end

    test "switching to the exclusions tab shows the patterns section and the tester", %{
      conn: conn
    } do
      {:ok, live, _html} = live(conn, ~p"/automation")

      html = render_click(element(live, "#tab-exclusions"))

      assert html =~ "Padrões Regex para Ignorar Ruídos de Extrato"
      assert html =~ "Testador Rápido de Regex"
      refute html =~ "Regras de Pareamento e Criação de Espelho"
    end
  end

  describe "transfer rules" do
    test "renders a rule as a flow card with accounts, mirror badge and pattern chips", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      transfer_rule_fixture(%{
        label: "Aporte Reserva de Emergência",
        description_patterns: ["TED NUBANK RESERVA", "PIX NUBANK APORTE"],
        source_account_id: source.id,
        destination_account_id: destination.id,
        create_mirror: true
      })

      {:ok, _live, html} = live(conn, ~p"/automation")

      assert html =~ "Aporte Reserva de Emergência"
      assert html =~ source.name
      assert html =~ destination.name
      assert html =~ "Gera Espelho"
      assert html =~ "Padrões no extrato:"
      assert html =~ "TED NUBANK RESERVA"
      assert html =~ "PIX NUBANK APORTE"
    end

    test "creates a transfer rule through the modal", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      {:ok, live, _html} = live(conn, ~p"/automation")

      html = render_click(element(live, "#new-rule-button"))
      assert html =~ "Nova Regra de Transferência"

      html =
        live
        |> form("#transfer-rule-form", %{
          "transfer_rule" => %{
            "label" => "Regra Criada no Modal",
            "description_patterns_raw" => "PIX CRIADO, TED CRIADO",
            "source_account_id" => source.id,
            "destination_account_id" => destination.id,
            "create_mirror" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Regra Criada no Modal"
      assert html =~ "PIX CRIADO"
      assert html =~ "TED CRIADO"
    end

    test "edits a transfer rule with the patterns pre-filled", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      rule =
        transfer_rule_fixture(%{
          label: "Rótulo Antigo",
          description_patterns: ["PIX UM", "PIX DOIS"],
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      {:ok, live, _html} = live(conn, ~p"/automation")

      html =
        live
        |> element("button[phx-click='edit_transfer'][phx-value-id='#{rule.id}']")
        |> render_click()

      assert html =~ "Editar Regra de Transferência"
      assert html =~ "PIX UM, PIX DOIS"

      html =
        live
        |> form("#transfer-rule-form", %{
          "transfer_rule" => %{
            "label" => "Rótulo Novo",
            "description_patterns_raw" => "PIX UM, PIX TRES",
            "source_account_id" => source.id,
            "destination_account_id" => destination.id,
            "create_mirror" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Rótulo Novo"
      refute html =~ "Rótulo Antigo"

      reloaded = Transactions.get_transfer_rule!(user(), rule.id)
      assert reloaded.label == "Rótulo Novo"
      assert reloaded.description_patterns == ["PIX UM", "PIX TRES"]
    end

    test "deletes a transfer rule behind a confirmation guard", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      rule =
        transfer_rule_fixture(%{
          label: "Regra Descartável",
          description_patterns: ["PIX SUMIR"],
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      {:ok, live, _html} = live(conn, ~p"/automation")

      delete_button =
        element(live, "button[phx-click='delete_transfer'][phx-value-id='#{rule.id}']")

      assert render(delete_button) =~ "data-confirm"

      html = render_click(delete_button)
      refute html =~ "Regra Descartável"
      assert Transactions.list_transfer_rules(user()) == []
    end
  end

  describe "exclusion patterns" do
    test "the header button on the exclusions tab opens the exclusion form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/automation")

      html = render_click(element(live, "#tab-exclusions"))
      assert html =~ "Novo Padrão Regex de Ruído"

      html = render_click(element(live, "#new-rule-button"))

      assert html =~ "Novo Padrão Regex de Ruído"
      assert has_element?(live, "#exclusion-form input[name='bulk_ignore_pattern[pattern]']")

      assert has_element?(
               live,
               "#exclusion-form input[name='bulk_ignore_pattern[description]']"
             )

      refute has_element?(live, "#transfer-rule-form")
    end

    test "creates a pattern through the modal", %{conn: conn} do
      pattern = "^AVISO DE CREDITO"

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))
      render_click(element(live, "#new-rule-button"))

      html =
        live
        |> form("#exclusion-form", %{
          "bulk_ignore_pattern" => %{
            "pattern" => pattern,
            "description" => "Ignora avisos informativos"
          }
        })
        |> render_submit()

      assert html =~ pattern
      assert html =~ "Ignora avisos informativos"
    end

    test "edits a pattern through a pre-filled modal and persists it", %{conn: conn} do
      original = "^SALDO ANTERIOR"
      updated = "^SALDO ATUAL"

      {:ok, record} =
        Transactions.create_bulk_ignore_pattern(user(), %{
          pattern: original,
          description: "Motivo antigo"
        })

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))

      html =
        live
        |> element("button[phx-click='edit_exclusion'][phx-value-id='#{record.id}']")
        |> render_click()

      assert html =~ "Editar Padrão Regex de Ruído"

      # Asserted on the input itself: the row behind the modal also renders the
      # pattern, so a plain `html =~ original` would pass on an empty modal.
      assert render(element(live, "#exclusion-form input[name='bulk_ignore_pattern[pattern]']")) =~
               ~s(value="#{original}")

      assert render(
               element(live, "#exclusion-form input[name='bulk_ignore_pattern[description]']")
             ) =~ ~s(value="Motivo antigo")

      html =
        live
        |> form("#exclusion-form", %{
          "bulk_ignore_pattern" => %{"pattern" => updated, "description" => "Motivo novo"}
        })
        |> render_submit()

      assert html =~ updated
      assert html =~ "Motivo novo"
      refute html =~ "Motivo antigo"

      reloaded = Transactions.get_bulk_ignore_pattern!(user(), record.id)
      assert reloaded.pattern == updated
      assert reloaded.description == "Motivo novo"
    end

    test "rejects an invalid regex instead of saving it", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))
      render_click(element(live, "#new-rule-button"))

      html =
        live
        |> form("#exclusion-form", %{
          "bulk_ignore_pattern" => %{"pattern" => "[invalid(", "description" => "Quebrada"}
        })
        |> render_submit()

      assert html =~ "Regex inválida"
      assert Transactions.list_bulk_ignore_patterns(user()) == []
    end

    test "deletes a pattern behind a confirmation guard", %{conn: conn} do
      pattern = "^TARIFA"

      {:ok, record} =
        Transactions.create_bulk_ignore_pattern(user(), %{
          pattern: pattern,
          description: "Tarifas"
        })

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))

      delete_button =
        element(live, "button[phx-click='delete_exclusion'][phx-value-id='#{record.id}']")

      assert render(delete_button) =~ "data-confirm"

      html = render_click(delete_button)
      refute html =~ pattern
      assert Transactions.list_bulk_ignore_patterns(user()) == []
    end

    test "a pattern row renders only its pattern and its description", %{conn: conn} do
      pattern = "^RENDIMENTO"

      {:ok, record} =
        Transactions.create_bulk_ignore_pattern(user(), %{
          pattern: pattern,
          description: "Ignora rendimentos automáticos"
        })

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))

      row_html = render(element(live, "#pattern-#{record.id}"))

      assert row_html =~ pattern
      assert row_html =~ "Ignora rendimentos automáticos"
      refute row_html =~ "Aplicado"
    end
  end

  describe "regex tester" do
    test "reports the matching pattern source text, not its description", %{conn: conn} do
      pattern = "^SALDO ANTERIOR"

      {:ok, _record} =
        Transactions.create_bulk_ignore_pattern(user(), %{
          pattern: pattern,
          description: "Linhas informativas de saldo"
        })

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))

      live
      |> form("#regex-tester-form", %{"description" => "SALDO ANTERIOR CONTA CORRENTE"})
      |> render_change()

      verdict = render(element(live, "#regex-test-result"))

      assert verdict =~ "Corresponde à regra:"
      assert verdict =~ pattern
      refute verdict =~ "Linhas informativas de saldo"
    end

    test "reports the keep verdict when no pattern matches", %{conn: conn} do
      {:ok, _record} =
        Transactions.create_bulk_ignore_pattern(user(), %{
          pattern: "^SALDO ANTERIOR",
          description: "Saldo"
        })

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))

      html =
        live
        |> form("#regex-tester-form", %{"description" => "MERCADO LIVRE COMPRA"})
        |> render_change()

      assert html =~ "Nenhum padrão de exclusão casou."
    end

    test "skips patterns that do not compile instead of crashing", %{conn: conn} do
      CashLens.Repo.insert_all("bulk_ignore_patterns", [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(CashLens.Repo.current_user_id()),
          pattern: "[broken(",
          description: "Padrão corrompido",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))

      html =
        live
        |> form("#regex-tester-form", %{"description" => "QUALQUER COISA"})
        |> render_change()

      assert html =~ "Nenhum padrão de exclusão casou."
    end
  end

  describe "form validation" do
    test "validate_transfer keeps the typed comma string and persists nothing", %{
      conn: conn,
      source: source
    } do
      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#new-rule-button"))

      html =
        live
        |> form("#transfer-rule-form", %{
          "transfer_rule" => %{
            "label" => "Rascunho",
            "description_patterns_raw" => "PIX UM, TED DOIS",
            "source_account_id" => source.id,
            "destination_account_id" => "",
            "create_mirror" => "true"
          }
        })
        |> render_change()

      # The raw field is form-only: it has no schema column, so it only survives
      # the round trip because `transfer_form_with_raw/2` puts it back.
      assert render(
               element(
                 live,
                 "#transfer-rule-form input[name='transfer_rule[description_patterns_raw]']"
               )
             ) =~ ~s(value="PIX UM, TED DOIS")

      assert html =~ "Nova Regra de Transferência"
      assert Transactions.list_transfer_rules(user()) == []
    end

    test "save_transfer re-renders the changeset errors instead of saving", %{
      conn: conn,
      source: source
    } do
      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#new-rule-button"))

      html =
        live
        |> form("#transfer-rule-form", %{
          "transfer_rule" => %{
            "label" => "Sem Destino",
            "description_patterns_raw" => "PIX SEM DESTINO",
            "source_account_id" => source.id,
            "destination_account_id" => "",
            "create_mirror" => "true"
          }
        })
        |> render_submit()

      assert Transactions.list_transfer_rules(user()) == []
      assert has_element?(live, "#transfer-rule-form")
      refute html =~ "Regra de transferência salva!"

      assert render(
               element(
                 live,
                 "#transfer-rule-form input[name='transfer_rule[description_patterns_raw]']"
               )
             ) =~ ~s(value="PIX SEM DESTINO")
    end

    test "validate_exclusion reports the regex error and persists nothing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/automation")
      render_click(element(live, "#tab-exclusions"))
      render_click(element(live, "#new-rule-button"))

      html =
        live
        |> form("#exclusion-form", %{
          "bulk_ignore_pattern" => %{"pattern" => "[aberto(", "description" => "Rascunho"}
        })
        |> render_change()

      assert html =~ "Regex inválida"
      assert Transactions.list_bulk_ignore_patterns(user()) == []

      assert render(element(live, "#exclusion-form input[name='bulk_ignore_pattern[pattern]']")) =~
               ~s(value="[aberto(")
    end
  end

  describe "reapply automatic rules" do
    setup %{source: source, destination: destination} do
      category_fixture(%{name: "Transfer", slug: "transfer"})
      %{source: source, destination: destination}
    end

    defp create_rule(source, destination, patterns, create_mirror) do
      {:ok, rule} =
        Transactions.create_transfer_rule(user(), %{
          label: "Regra de Reaplicação",
          description_patterns: patterns,
          source_account_id: source.id,
          destination_account_id: destination.id,
          create_mirror: create_mirror
        })

      rule
    end

    defp click_reapply(conn) do
      {:ok, live, _html} = live(conn, ~p"/automation")

      live
      |> element("#reapply-rules")
      |> render_click()
    end

    test "flashes the empty result when no transaction is categorized", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      transaction_fixture(%{
        account_id: source.id,
        description: "compra no mercado",
        category_id: nil,
        amount: "-50.00"
      })

      create_rule(source, destination, ["NUNCA CASA"], false)

      html = click_reapply(conn)

      assert html =~ "nenhuma transação nova categorizada como transferência."
    end

    test "flashes the singular result for exactly one categorized transaction", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      # The transaction is created before the rule on purpose: creating it after
      # would let the ingest-time applier categorize it, and the reapply delta
      # would be zero.
      # `create_mirror: false` categorizes the source transaction only, so the
      # delta is exactly one and the singular clause is the only possible match.
      transaction_fixture(%{
        account_id: source.id,
        description: "APORTE RESERVA MENSAL",
        category_id: nil,
        amount: "-200.00"
      })

      create_rule(source, destination, ["aporte reserva"], false)

      html = click_reapply(conn)

      assert html =~ "1 transação categorizada como transferência."
      refute html =~ "transações categorizadas"
    end

    test "flashes the plural result when the mirror is created too", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      # With the mirror enabled both legs get the transfer category, so the
      # delta is two and the plural clause is exercised. Same ordering reason as
      # the singular case above.
      transaction_fixture(%{
        account_id: source.id,
        description: "APORTE RESERVA MENSAL",
        category_id: nil,
        amount: "-200.00"
      })

      create_rule(source, destination, ["aporte reserva"], true)

      html = click_reapply(conn)

      assert html =~ "2 transações categorizadas como transferência."
    end
  end

  describe "tenancy" do
    setup do
      %{a: other} = cross_tenant()

      {rule, pattern} =
        CashLens.Tenancy.acting_as(other, fn ->
          {transfer_rule_fixture(%{user: other, label: "Foreign rule"}),
           insert_bulk_ignore_pattern(%{user: other, pattern: "foreign-pattern"})}
        end)

      %{other: other, rule: rule, pattern: pattern}
    end

    test "lists only the logged-in user's rules and patterns", %{conn: conn} do
      transfer_rule_fixture(%{label: "My rule"})
      {:ok, live, html} = live(conn, ~p"/automation")

      assert html =~ "My rule"
      refute html =~ "Foreign rule"
      refute render_click(element(live, "#tab-exclusions")) =~ "foreign-pattern"
    end

    test "forged ids in edit and delete events flash an error and change nothing", ctx do
      %{conn: conn, other: other, rule: rule, pattern: pattern} = ctx
      {:ok, live, _html} = live(conn, ~p"/automation")

      for {event, id} <- [
            {"edit_transfer", rule.id},
            {"delete_transfer", rule.id},
            {"edit_exclusion", pattern.id},
            {"delete_exclusion", pattern.id}
          ] do
        html = render_hook(live, event, %{"id" => id})
        assert html =~ "não encontrad", "#{event} did not flash"
        refute html =~ "Foreign rule"
      end

      CashLens.Tenancy.acting_as(other, fn ->
        assert Transactions.get_transfer_rule!(other, rule.id).label == "Foreign rule"

        assert Transactions.get_bulk_ignore_pattern!(other, pattern.id).pattern ==
                 "foreign-pattern"
      end)
    end

    test "reapplying rules for the user does not touch the other user's transactions", ctx do
      %{conn: conn, other: other} = ctx

      tx =
        CashLens.Tenancy.acting_as(other, fn ->
          transaction_fixture(%{user: other, description: "untouched"})
        end)

      {:ok, live, _html} = live(conn, ~p"/automation")
      render_hook(live, "reapply_rules", %{})

      assert CashLens.Tenancy.acting_as(other, fn ->
               CashLens.Repo.get!(CashLens.Transactions.Transaction, tx.id)
             end) == tx
    end
  end
end
