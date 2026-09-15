defmodule CashLensWeb.TransactionLive.FormComponent do
  @moduledoc """
  The manual transaction form, rendered as a modal overlaid on the statement
  for both `/transactions/new` and `/transactions/:id/edit` (CL-10).

  Income and expense are not two modes here: the sign the user types in the
  amount field *is* the direction, and it is written straight to
  `Transaction.amount`. `CashLens.Transactions.AmountInput` owns the parsing;
  this component only keeps the raw typed string around so the live colour and
  label feedback can react on every keystroke without reformatting what the
  user is still typing.
  """

  use CashLensWeb, :live_component

  alias CashLens.CreditCards
  alias CashLens.Transactions
  alias CashLens.Transactions.AmountInput

  @impl true
  def update(%{transaction: transaction, action: action} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:amount_input, AmountInput.to_input_value(transaction.amount))
     |> assign(:amount_kind, AmountInput.kind(transaction.amount))
     |> assign(:amount_error, nil)
     |> assign(:links, if(action == :edit, do: build_links(transaction), else: []))
     |> assign(:form, to_form(Transactions.change_transaction(transaction)))}
  end

  @impl true
  def handle_event("validate", %{"transaction" => params}, socket) do
    {socket, params} = take_amount(socket, params)

    changeset =
      socket.assigns.transaction
      |> Transactions.change_transaction(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"transaction" => params}, socket) do
    {socket, params} = take_amount(socket, params)

    if socket.assigns.amount_error do
      changeset =
        socket.assigns.transaction
        |> Transactions.change_transaction(params)
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, :form, to_form(changeset))}
    else
      persist(socket, socket.assigns.action, params)
    end
  end

  defp persist(socket, :new, params) do
    case Transactions.create_transaction(params) do
      {:ok, :duplicate} ->
        send(self(), {:transaction_duplicate})
        {:noreply, socket}

      {:ok, transaction} ->
        send(self(), {:transaction_saved, transaction, :new})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp persist(socket, :edit, params) do
    case Transactions.update_transaction(socket.assigns.transaction, params) do
      {:ok, transaction} ->
        send(self(), {:transaction_saved, transaction, :edit})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Keeps the raw string for the live feedback and hands the changeset a parsed
  # decimal (or nothing, so the usual "can't be blank" applies) instead.
  defp take_amount(socket, params) do
    raw = Map.get(params, "amount", "")

    {value, error} =
      case AmountInput.parse(raw) do
        {:ok, decimal} -> {decimal, nil}
        :empty -> {nil, nil}
        :error -> {nil, "Valor inválido"}
      end

    socket =
      socket
      |> assign(:amount_input, raw)
      |> assign(:amount_kind, AmountInput.kind(raw))
      |> assign(:amount_error, error)

    {socket, Map.put(params, "amount", value)}
  end

  defp build_links(transaction) do
    []
    |> add_reimbursement_links(transaction)
    |> add_transfer_links(transaction)
    |> add_installment_link(transaction)
    |> add_statement_link(transaction)
    |> Enum.reverse()
  end

  defp add_reimbursement_links(links, %{reimbursement_link_key: nil} = transaction) do
    case transaction.reimbursement_status do
      nil -> links
      status -> [{"Reembolso", "Marcada como reembolsável (#{status})"} | links]
    end
  end

  defp add_reimbursement_links(links, transaction) do
    transaction.reimbursement_link_key
    |> List.wrap()
    |> Transactions.get_reimbursement_pairs()
    |> Map.get(transaction.reimbursement_link_key, [])
    |> counterparts(transaction)
    |> Enum.reduce(links, fn other, acc ->
      [{"Reembolso", "Vinculada a #{describe(other)}"} | acc]
    end)
  end

  defp add_transfer_links(links, %{transfer_key: nil}), do: links

  defp add_transfer_links(links, transaction) do
    transaction.transfer_key
    |> List.wrap()
    |> Transactions.get_transfer_pairs()
    |> Map.get(transaction.transfer_key, [])
    |> counterparts(transaction)
    |> Enum.reduce(links, fn other, acc ->
      [{"Transferência", "Par com #{describe(other)}"} | acc]
    end)
  end

  defp add_installment_link(links, %{installment_group: %{description_pattern: pattern}}),
    do: [{"Parcelamento", "Pertence ao grupo #{pattern}"} | links]

  defp add_installment_link(links, _transaction), do: links

  defp add_statement_link(links, transaction) do
    case CreditCards.get_statement_paid_by(transaction.id) do
      nil ->
        links

      statement ->
        [
          {"Fatura",
           "Concilia a fatura de #{CashLensWeb.Formatters.format_date(statement.competencia)}"}
          | links
        ]
    end
  end

  defp counterparts(transactions, transaction) do
    Enum.reject(transactions, &(&1.id == transaction.id))
  end

  defp describe(transaction) do
    "#{transaction.description} (#{CashLensWeb.Formatters.format_currency(transaction.amount)})"
  end

  defp amount_text_class(:expense), do: "text-error"
  defp amount_text_class(:income), do: "text-success"
  defp amount_text_class(_neutral), do: "text-base-content"

  defp amount_hint(:expense), do: "Despesa (Saída)"
  defp amount_hint(:income), do: "Receita (Entrada)"
  defp amount_hint(_neutral), do: "Informe o valor com sinal"

  defp modal_title(:edit), do: "Editar Transação"
  defp modal_title(_new), do: "Nova Transação Manual"

  defp modal_subtitle(:edit), do: "Ajuste os dados do lançamento financeiro"
  defp modal_subtitle(_new), do: "Preencha os dados do lançamento financeiro"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="transaction-form-modal"
      class="modal modal-open"
      phx-window-keydown="close_transaction_modal"
      phx-key="escape"
    >
      <div class="modal-box max-w-xl p-0 bg-base-100 border border-base-300 rounded-3xl shadow-2xl">
        <div class="px-6 py-4 border-b border-base-200 flex items-center justify-between bg-base-200/40">
          <div>
            <h3 class="text-sm font-black uppercase tracking-tighter">
              {modal_title(@action)}
            </h3>
            <p class="text-xs text-base-content/50">{modal_subtitle(@action)}</p>
          </div>
          <button
            id="transaction-form-modal-close"
            type="button"
            phx-click="close_transaction_modal"
            class="btn btn-sm btn-circle btn-ghost"
            aria-label="Fechar"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          :let={f}
          for={@form}
          id="transaction-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          class="p-6 space-y-4"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="form-control w-full">
              <label class="label justify-between" for="transaction-amount-input">
                <span class="label-text font-bold">Valor (R$)</span>
                <span
                  id="transaction-amount-hint"
                  data-kind={@amount_kind}
                  class={["text-xs font-bold", amount_text_class(@amount_kind)]}
                >
                  {amount_hint(@amount_kind)}
                </span>
              </label>
              <input
                type="text"
                id="transaction-amount-input"
                name="transaction[amount]"
                value={@amount_input}
                inputmode="decimal"
                autocomplete="off"
                required
                placeholder="-150,00"
                class={[
                  "input input-bordered w-full font-mono font-bold",
                  amount_text_class(@amount_kind)
                ]}
              />
              <p :if={@amount_error} class="mt-1 flex gap-2 items-center text-xs text-error">
                <.icon name="hero-exclamation-circle" class="size-4" />
                {@amount_error}
              </p>
              <p class="text-xs text-base-content/50 mt-1">
                Use <b>-</b> para despesa (ex.: -80,00) ou sem sinal para receita (ex.: 2.500,00)
              </p>
            </div>

            <.input field={f[:date]} type="date" label="Data" required />
          </div>

          <.input
            field={f[:description]}
            type="text"
            label="Descrição"
            required
            placeholder="Ex.: Aluguel, Supermercado, Consulta..."
          />

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={f[:account_id]}
              type="select"
              label="Conta Bancária / Cartão"
              options={Enum.map(@accounts, &{CashLensWeb.Formatters.account_label(&1), &1.id})}
              required
            />
            <.input
              field={f[:category_id]}
              type="select"
              label="Categoria"
              options={Enum.map(@categories, &{CashLens.Categories.Category.full_name(&1), &1.id})}
              prompt="(Pendente de categoria)"
            />
          </div>

          <details :if={@links != []} id="transaction-links" class="rounded-2xl bg-base-200/50 p-3">
            <summary class="cursor-pointer text-xs font-black uppercase tracking-wider">
              Conciliações &amp; Rastreabilidade
            </summary>
            <ul class="mt-2 space-y-1 text-xs text-base-content/70">
              <li :for={{kind, detail} <- @links} class="flex gap-2">
                <span class="font-bold">{kind}:</span>
                <span>{detail}</span>
              </li>
            </ul>
            <p class="mt-2 text-xs text-warning">
              Alterar valor, data ou conta desta transação afeta os vínculos acima.
            </p>
          </details>

          <.input
            field={f[:notes]}
            type="textarea"
            label="Observações / Recibos"
            placeholder="Informações adicionais, número de protocolo..."
          />

          <div class="flex items-center justify-end gap-2 pt-2 border-t border-base-200">
            <button type="button" phx-click="close_transaction_modal" class="btn btn-ghost">
              Cancelar
            </button>
            <.button phx-disable-with="Salvando..." variant="primary">
              Salvar Lançamento
            </.button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/40 backdrop-blur-sm" phx-click="close_transaction_modal">
      </div>
    </div>
    """
  end
end
