defmodule CashLensWeb.AutomationLive.Index do
  @moduledoc """
  The Automation Center (CL-17).

  Merges the two former rule screens — `/admin/exclusion_rules` and
  `/admin/transfer_rules` — into a single tabbed screen at `/automation`. The
  active tab lives in the `tab` query param (`transfers` by default, or
  `exclusions`) so switching tabs is a `live_patch` and never remounts.

  Both rule kinds are created and edited in the same overlaid modal; the two
  fixed side forms of the old screens are gone. Because the two schemas use
  different form param keys (`transfer_rule` vs `bulk_ignore_pattern`), the
  events are named per rule kind instead of being shared.

  By design the screen renders no count or quantity indicator of any kind: no
  metric cards and no numeric suffix on the tab labels.
  """

  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Transactions.BulkIgnorePattern
  alias CashLens.Transactions.TransferRule

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 pb-2 border-b border-base-300">
        <div>
          <h1 class="text-2xl font-black tracking-tighter">Central de Automações & Regras</h1>
          <p class="text-xs text-base-content/60 mt-0.5">
            Automatize espelhamento de transferências entre suas contas e filtre ruídos de extrato
            por regex.
          </p>
        </div>

        <div class="flex items-center gap-3">
          <div class="flex items-center gap-1 p-1 bg-base-200 rounded-xl text-xs font-bold">
            <.tab_button
              id="tab-transfers"
              tab="transfers"
              active={@tab}
              icon="hero-arrows-right-left"
            >
              Regras de Transferência
            </.tab_button>
            <.tab_button id="tab-exclusions" tab="exclusions" active={@tab} icon="hero-no-symbol">
              Exclusão de Ruído / Regex
            </.tab_button>
          </div>

          <button
            id="new-rule-button"
            type="button"
            phx-click="new_rule"
            class="btn btn-primary btn-sm rounded-xl"
          >
            <.icon name="hero-plus" class="size-4" />
            {new_rule_label(@tab)}
          </button>
        </div>
      </div>

      <div :if={@tab == "transfers"} class="space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
          <h2 class="text-xs font-black uppercase tracking-wider">
            Regras de Pareamento e Criação de Espelho
          </h2>
          <div class="flex items-center gap-3">
            <span class="text-xs text-base-content/60">
              Quando a descrição da transação na conta de origem der match, a regra vincula ou gera
              a transação na conta destino.
            </span>
            <button
              id="reapply-rules"
              type="button"
              phx-click="reapply_rules"
              phx-disable-with="Processando..."
              class="btn btn-outline btn-xs rounded-xl whitespace-nowrap"
            >
              <.icon name="hero-play" class="size-3" /> Reaplicar Regras Automáticas
            </button>
          </div>
        </div>

        <div class="space-y-3">
          <.transfer_card :for={rule <- @transfer_rules} rule={rule} />
          <p :if={@transfer_rules == []} class="p-10 text-center opacity-30 italic">
            Nenhuma regra de transferência configurada.
          </p>
        </div>
      </div>

      <div :if={@tab == "exclusions"} class="space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
          <h2 class="text-xs font-black uppercase tracking-wider">
            Padrões Regex para Ignorar Ruídos de Extrato
          </h2>
          <span class="text-xs text-base-content/60">
            Transações que casarem com esses padrões serão descartadas ou ignoradas nas sugestões
            em lote.
          </span>
        </div>

        <.regex_tester verdict={@regex_verdict} />

        <div class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden">
          <div class="card-body p-0 divide-y divide-base-200">
            <.pattern_row :for={pattern <- @patterns} pattern={pattern} />
            <p :if={@patterns == []} class="p-10 text-center opacity-30 italic">
              Nenhum padrão cadastrado.
            </p>
          </div>
        </div>
      </div>

      <.modal :if={@rule_modal} id="rule-modal" show on_cancel={JS.push("close_modal")}>
        <h3 class="text-base font-bold">{@rule_modal.title}</h3>
        <p class="text-xs text-base-content/60 mt-0.5 mb-6">{@rule_modal.subtitle}</p>

        <.transfer_form :if={@rule_modal.kind == :transfer} form={@form} accounts={@accounts} />
        <.exclusion_form :if={@rule_modal.kind == :exclusion} form={@form} />
      </.modal>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "px-4 py-2 rounded-lg transition flex items-center gap-2",
        @active == @tab && "bg-base-100 text-primary shadow-sm",
        @active != @tab && "text-base-content/60 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :rule, :map, required: true

  defp transfer_card(assigns) do
    ~H"""
    <div
      id={"transfer-rule-#{@rule.id}"}
      class="card bg-base-100 border border-base-300 shadow-sm p-5 flex flex-col md:flex-row md:items-center justify-between gap-4"
    >
      <div class="space-y-2">
        <div class="flex items-center gap-2">
          <span class="text-sm font-bold">{@rule.label || "Regra sem rótulo"}</span>
          <span
            :if={@rule.create_mirror}
            class="px-2 py-0.5 rounded-full text-[10px] font-extrabold bg-primary/10 text-primary border border-primary/20"
          >
            Gera Espelho
          </span>
        </div>

        <div class="flex items-center gap-2 text-xs font-semibold">
          <span class="px-2.5 py-1 bg-base-200 rounded-lg border border-base-300">
            {@rule.source_account.name}
          </span>
          <.icon name="hero-arrow-long-right" class="size-4 opacity-40" />
          <span class="px-2.5 py-1 bg-base-200 rounded-lg border border-base-300">
            {@rule.destination_account.name}
          </span>
        </div>

        <div class="flex flex-wrap items-center gap-1.5 pt-1">
          <span class="text-[11px] text-base-content/60 font-medium">Padrões no extrato:</span>
          <span
            :for={pattern <- @rule.description_patterns}
            class="text-[10px] bg-base-200 font-mono px-2 py-0.5 rounded border border-base-300"
          >
            {pattern}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-2 self-end md:self-center">
        <button
          type="button"
          phx-click="edit_transfer"
          phx-value-id={@rule.id}
          class="btn btn-ghost btn-xs rounded-lg"
        >
          Editar
        </button>
        <button
          type="button"
          phx-click="delete_transfer"
          phx-value-id={@rule.id}
          data-confirm="Tem certeza que deseja excluir esta regra de transferência?"
          class="btn btn-ghost btn-xs text-error rounded-lg"
        >
          Excluir
        </button>
      </div>
    </div>
    """
  end

  attr :pattern, :map, required: true

  defp pattern_row(assigns) do
    ~H"""
    <div
      id={"pattern-#{@pattern.id}"}
      class="p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-3 hover:bg-base-200/50 transition"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-mono text-xs font-bold bg-base-200 px-2 py-0.5 rounded border border-base-300">
          {@pattern.pattern}
        </span>
        <span class="text-[11px] text-base-content/60 font-medium">{@pattern.description}</span>
      </div>
      <div class="flex items-center gap-2 self-end sm:self-center">
        <button
          type="button"
          phx-click="edit_exclusion"
          phx-value-id={@pattern.id}
          class="btn btn-ghost btn-xs rounded-lg"
        >
          Editar
        </button>
        <button
          type="button"
          phx-click="delete_exclusion"
          phx-value-id={@pattern.id}
          data-confirm="Tem certeza que deseja excluir este padrão?"
          class="btn btn-ghost btn-xs text-error rounded-lg"
        >
          Excluir
        </button>
      </div>
    </div>
    """
  end

  attr :verdict, :any, required: true

  defp regex_tester(assigns) do
    ~H"""
    <div class="card bg-primary/5 border border-primary/20 p-5 space-y-3">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
        <span class="text-xs font-bold flex items-center gap-1.5">
          <.icon name="hero-bolt" class="size-4 text-primary" /> Testador Rápido de Regex
        </span>
        <span class="text-[11px] text-base-content/60 font-medium">
          Digite uma descrição de extrato para testar contra as regras
        </span>
      </div>

      <form id="regex-tester-form" phx-change="test_regex" phx-submit="test_regex">
        <input
          type="text"
          name="description"
          value={@verdict && @verdict.description}
          placeholder="Ex: SALDO ANTERIOR CONTA CORRENTE ou AVISO DE CREDITO"
          class="input input-bordered input-sm w-full rounded-xl text-xs"
        />
      </form>

      <div
        :if={@verdict && @verdict.pattern}
        id="regex-test-result"
        class="text-xs font-semibold p-2.5 rounded-xl bg-success/15 text-success-content border border-success/30"
      >
        <strong>Corresponde à regra:</strong>
        <code class="font-mono">{@verdict.pattern}</code>
        — Esta transação seria <strong>ignorada</strong>
        no extrato.
      </div>
      <div
        :if={@verdict && is_nil(@verdict.pattern)}
        id="regex-test-result"
        class="text-xs font-semibold p-2.5 rounded-xl bg-base-200 border border-base-300"
      >
        Nenhum padrão de exclusão casou. Esta transação seria <strong>mantida normalmente</strong>.
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :accounts, :list, required: true

  defp transfer_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="transfer-rule-form"
      phx-submit="save_transfer"
      phx-change="validate_transfer"
      class="space-y-4"
    >
      <.input
        field={@form[:label]}
        type="text"
        label="Rótulo / Identificação da Regra"
        placeholder="ex. Envio Mensal para Reserva"
      />
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <.input
          field={@form[:source_account_id]}
          type="select"
          label="Conta de Origem"
          options={account_options(@accounts)}
          prompt="Selecione a conta de origem"
          required
        />
        <.input
          field={@form[:destination_account_id]}
          type="select"
          label="Conta de Destino"
          options={account_options(@accounts)}
          prompt="Selecione a conta de destino"
          required
        />
      </div>
      <.input
        field={@form[:description_patterns_raw]}
        type="text"
        label="Padrões de Descrição no Extrato (separados por vírgula)"
        placeholder="ex. PIX NUBANK, TED RESERVA"
        required
      />
      <.input
        field={@form[:create_mirror]}
        type="checkbox"
        label="Criar transação espelho automaticamente na conta destino"
      />
      <.modal_actions />
    </.form>
    """
  end

  attr :form, :any, required: true

  defp exclusion_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="exclusion-form"
      phx-submit="save_exclusion"
      phx-change="validate_exclusion"
      class="space-y-4"
    >
      <.input
        field={@form[:pattern]}
        type="text"
        label="Padrão Regex"
        placeholder="ex. ^SALDO ANTERIOR"
        required
      />
      <.input
        field={@form[:description]}
        type="text"
        label="Descrição"
        placeholder="ex. Ignora linhas informativas de saldo anterior do banco"
      />
      <.modal_actions />
    </.form>
    """
  end

  defp modal_actions(assigns) do
    ~H"""
    <div class="pt-2 flex items-center justify-end gap-2">
      <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm rounded-xl">
        Cancelar
      </button>
      <button type="submit" class="btn btn-primary btn-sm rounded-xl" phx-disable-with="Salvando...">
        Salvar Regra
      </button>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:accounts, Accounts.list_active_accounts())
     |> assign(:rule_modal, nil)
     |> assign(:form, nil)
     |> assign(:regex_verdict, nil)
     |> load_rules()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, normalize_tab(params["tab"]))}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/automation?tab=#{normalize_tab(tab)}")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("new_rule", _params, socket) do
    case socket.assigns.tab do
      "exclusions" -> {:noreply, open_exclusion_modal(socket, %BulkIgnorePattern{})}
      _transfers -> {:noreply, open_transfer_modal(socket, %TransferRule{})}
    end
  end

  def handle_event("edit_transfer", %{"id" => id}, socket) do
    {:noreply, open_transfer_modal(socket, Transactions.get_transfer_rule!(id))}
  end

  def handle_event("edit_exclusion", %{"id" => id}, socket) do
    {:noreply, open_exclusion_modal(socket, Transactions.get_bulk_ignore_pattern!(id))}
  end

  def handle_event("validate_transfer", %{"transfer_rule" => params}, socket) do
    changeset =
      socket.assigns.rule_modal.record
      |> Transactions.change_transfer_rule(parse_transfer_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, transfer_form_with_raw(changeset, params))}
  end

  def handle_event("save_transfer", %{"transfer_rule" => params}, socket) do
    record = socket.assigns.rule_modal.record
    attrs = parse_transfer_params(params)

    result =
      case record.id do
        nil -> Transactions.create_transfer_rule(attrs)
        _id -> Transactions.update_transfer_rule(record, attrs)
      end

    case result do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:success, "Regra de transferência salva!")
         |> close_modal()
         |> load_rules()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, transfer_form_with_raw(changeset, params))}
    end
  end

  def handle_event("delete_transfer", %{"id" => id}, socket) do
    rule = Transactions.get_transfer_rule!(id)
    {:ok, _} = Transactions.delete_transfer_rule(rule)

    {:noreply,
     socket
     |> put_flash(:success, "Regra de transferência excluída.")
     |> load_rules()}
  end

  def handle_event("validate_exclusion", %{"bulk_ignore_pattern" => params}, socket) do
    changeset =
      socket.assigns.rule_modal.record
      |> Transactions.change_bulk_ignore_pattern(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_exclusion", %{"bulk_ignore_pattern" => params}, socket) do
    record = socket.assigns.rule_modal.record

    result =
      case record.id do
        nil -> Transactions.create_bulk_ignore_pattern(params)
        _id -> Transactions.update_bulk_ignore_pattern(record, params)
      end

    case result do
      {:ok, _pattern} ->
        {:noreply,
         socket
         |> put_flash(:success, "Padrão salvo!")
         |> close_modal()
         |> load_rules()
         |> refresh_verdict()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete_exclusion", %{"id" => id}, socket) do
    pattern = Transactions.get_bulk_ignore_pattern!(id)
    {:ok, _} = Transactions.delete_bulk_ignore_pattern(pattern)

    {:noreply,
     socket
     |> put_flash(:success, "Padrão removido.")
     |> load_rules()
     |> refresh_verdict()}
  end

  def handle_event("test_regex", %{"description" => description}, socket) do
    {:noreply,
     assign(socket, :regex_verdict, build_verdict(socket.assigns.patterns, description))}
  end

  def handle_event("reapply_rules", _params, socket) do
    {:ok, categorized} = Transactions.reapply_transfer_rules()

    {:noreply, put_flash(socket, :success, reapply_message(categorized))}
  end

  defp load_rules(socket) do
    socket
    |> assign(:transfer_rules, Transactions.list_transfer_rules())
    |> assign(:patterns, Transactions.list_bulk_ignore_patterns())
  end

  defp close_modal(socket), do: socket |> assign(:rule_modal, nil) |> assign(:form, nil)

  defp open_transfer_modal(socket, %TransferRule{} = rule) do
    changeset = Transactions.change_transfer_rule(rule)
    raw = Enum.join(rule.description_patterns || [], ", ")

    socket
    |> assign(:rule_modal, %{
      kind: :transfer,
      record: rule,
      title: modal_title(:transfer, rule.id),
      subtitle: "Configure os critérios de acionamento automático."
    })
    |> assign(:form, transfer_form_with_raw(changeset, %{"description_patterns_raw" => raw}))
  end

  defp open_exclusion_modal(socket, %BulkIgnorePattern{} = pattern) do
    socket
    |> assign(:rule_modal, %{
      kind: :exclusion,
      record: pattern,
      title: modal_title(:exclusion, pattern.id),
      subtitle: "Defina a regex e o motivo pelo qual essas linhas do extrato devem ser ignoradas."
    })
    |> assign(:form, to_form(Transactions.change_bulk_ignore_pattern(pattern)))
  end

  defp modal_title(:transfer, nil), do: "Nova Regra de Transferência"
  defp modal_title(:transfer, _id), do: "Editar Regra de Transferência"
  defp modal_title(:exclusion, nil), do: "Novo Padrão Regex de Ruído"
  defp modal_title(:exclusion, _id), do: "Editar Padrão Regex de Ruído"

  defp new_rule_label("exclusions"), do: "Novo Padrão Regex de Ruído"
  defp new_rule_label(_transfers), do: "Nova Regra de Transferência"

  defp normalize_tab("exclusions"), do: "exclusions"
  defp normalize_tab(_other), do: "transfers"

  # `description_patterns_raw` is a form-only field: the schema stores an array,
  # while the modal edits a comma-separated string, so the raw value has to be
  # carried back into the form params on every render.
  defp transfer_form_with_raw(changeset, params) do
    raw = Map.get(params, "description_patterns_raw", "")

    changeset
    |> to_form()
    |> Map.update!(:params, &Map.put(&1, "description_patterns_raw", raw))
  end

  defp parse_transfer_params(params) do
    patterns =
      params
      |> Map.get("description_patterns_raw", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    params
    |> Map.delete("description_patterns_raw")
    |> Map.put("description_patterns", patterns)
  end

  defp refresh_verdict(%{assigns: %{regex_verdict: nil}} = socket), do: socket

  defp refresh_verdict(socket) do
    assign(
      socket,
      :regex_verdict,
      build_verdict(socket.assigns.patterns, socket.assigns.regex_verdict.description)
    )
  end

  defp build_verdict(_patterns, ""), do: nil

  defp build_verdict(patterns, description) do
    %{description: description, pattern: matching_pattern(patterns, description)}
  end

  # A pattern that no longer compiles (saved before the schema validation, or
  # inserted out of band) is skipped rather than crashing the tester.
  defp matching_pattern(patterns, description) do
    Enum.find_value(patterns, &matched_source(&1, description))
  end

  defp matched_source(pattern, description) do
    with {:ok, regex} <- Regex.compile(pattern.pattern, "i"),
         true <- Regex.match?(regex, description) do
      pattern.pattern
    else
      _not_a_match -> nil
    end
  end

  defp account_options(accounts), do: Enum.map(accounts, &{account_label(&1), &1.id})

  defp reapply_message(0),
    do: "Regras reaplicadas — nenhuma transação nova categorizada como transferência."

  defp reapply_message(1), do: "Regras reaplicadas — 1 transação categorizada como transferência."

  defp reapply_message(count),
    do: "Regras reaplicadas — #{count} transações categorizadas como transferência."
end
