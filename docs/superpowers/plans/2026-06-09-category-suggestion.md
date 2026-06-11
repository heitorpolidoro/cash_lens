# Sugestão de categoria por descrição — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transações sem categoria mostram um pill "Sugestão: X [aceitar]" derivado de como descrições idênticas (normalizadas) foram categorizadas no passado; nada é aplicado sem clique.

**Architecture:** Novo módulo `CashLens.Transactions.CategorySuggester` calcula sugestões on-the-fly (sem migration): carrega o histórico categorizado, normaliza via `Transaction.normalize_description/1` (já existente) e escolhe a categoria mais frequente (desempate: mais recente). **Correção em relação ao spec:** a lista de transações usa LiveView **streams** (linhas não ficam em assigns e só re-renderizam via `stream_insert`), então um assign `%{tx_id => sugestão}` não funcionaria; a sugestão viaja num **campo virtual** `:suggested_category` da própria `Transaction`, preenchido por `CategorySuggester.annotate/1` quando a lista é carregada (`Transactions.list_transactions/3`) e quando uma linha é re-inserida no stream. O pill reusa o evento `update_category` existente — aceitar dispara o fluxo atual, incluindo o `handle_bulk_suggestion` (propagação para iguais).

**Tech Stack:** Elixir, Phoenix LiveView (streams), Ecto, ExUnit.

---

## File Structure

- Create: `lib/cash_lens/transactions/category_suggester.ex` — cálculo das sugestões + annotate.
- Modify: `lib/cash_lens/transactions/transaction.ex` — campo virtual `:suggested_category`.
- Modify: `lib/cash_lens/transactions.ex` — `list_transactions/3` anota as sugestões.
- Modify: `lib/cash_lens_web/live/transaction_live/index.ex` — `stream_update_transaction/2` re-anota a linha atualizada.
- Modify: `lib/cash_lens_web/live/transaction_live/index.html.heex` — pill na célula de categoria.
- Test: `test/cash_lens/transactions/category_suggester_test.exs`
- Test: `test/cash_lens_web/live/transaction_live/category_suggestion_test.exs`

Fatos do código atual de que este plano depende (verificados):
- `Transaction.normalize_description/1` é pública: colapsa espaços → trim → upcase → remove acentos.
- `Transactions.create_transaction/1` casta `category_id` (fixtures podem criar histórico categorizado) e NÃO roda o AutoCategorizer.
- `transaction_fixture/1` (em `CashLens.TransactionsFixtures`) cria a própria conta quando `account_id` não é passado — o dedup key inclui `account_id`, então fixtures não colidem.
- O evento `"update_category"` no `index.ex` recebe `%{"transaction_id" => id, "category_id" => category_id}` e já chama `update_transaction_category/2` + `handle_bulk_suggestion` + `stream_update_transaction`.
- `timestamps(type: :utc_datetime)` — precisão de segundo; testes de desempate por recência precisam setar `inserted_at` explicitamente via `Repo.update_all`.

---

### Task 1: `CategorySuggester` + campo virtual

**Files:**
- Create: `lib/cash_lens/transactions/category_suggester.ex`
- Modify: `lib/cash_lens/transactions/transaction.ex` (campo virtual)
- Test: `test/cash_lens/transactions/category_suggester_test.exs`

- [ ] **Step 1: Escrever os testes que falham**

Crie `test/cash_lens/transactions/category_suggester_test.exs`:

```elixir
defmodule CashLens.Transactions.CategorySuggesterTest do
  use CashLens.DataCase, async: false

  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures
  import Ecto.Query

  alias CashLens.Repo
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.Transaction

  describe "suggest_for/1" do
    test "matches normalized descriptions (case, accents, spacing)" do
      category = category_fixture(name: "Padaria")
      transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)

      target = transaction_fixture(description: "  Padaria São José ", amount: "10.0")

      suggestions = CategorySuggester.suggest_for([target])

      assert suggestions[target.id] == %{
               category_id: category.id,
               category_name: "Padaria"
             }
    end

    test "picks the most frequent category for a description" do
      frequent = category_fixture(name: "Frequente")
      rare = category_fixture(name: "Rara")

      transaction_fixture(description: "MERCADO X", category_id: frequent.id, amount: "1.0")
      transaction_fixture(description: "MERCADO X", category_id: frequent.id, amount: "2.0")
      transaction_fixture(description: "MERCADO X", category_id: rare.id, amount: "3.0")

      target = transaction_fixture(description: "Mercado X", amount: "9.0")

      assert %{} = suggestions = CategorySuggester.suggest_for([target])
      assert suggestions[target.id].category_id == frequent.id
    end

    test "breaks frequency ties toward the most recent occurrence" do
      old_cat = category_fixture(name: "Antiga")
      new_cat = category_fixture(name: "Recente")

      old_tx = transaction_fixture(description: "FARMACIA Y", category_id: old_cat.id, amount: "1.0")
      new_tx = transaction_fixture(description: "FARMACIA Y", category_id: new_cat.id, amount: "2.0")

      # timestamps have second precision; set distinct inserted_at explicitly
      Repo.update_all(from(t in Transaction, where: t.id == ^old_tx.id),
        set: [inserted_at: ~U[2026-01-01 10:00:00Z]]
      )

      Repo.update_all(from(t in Transaction, where: t.id == ^new_tx.id),
        set: [inserted_at: ~U[2026-06-01 10:00:00Z]]
      )

      target = transaction_fixture(description: "Farmacia Y", amount: "9.0")

      assert CategorySuggester.suggest_for([target])[target.id].category_id == new_cat.id
    end

    test "returns no entry for descriptions without categorized history" do
      target = transaction_fixture(description: "NUNCA VISTA")
      assert CategorySuggester.suggest_for([target]) == %{}
    end

    test "ignores transactions that already have a category" do
      category = category_fixture(name: "Qualquer")
      categorized = transaction_fixture(description: "JA TEM", category_id: category.id)

      assert CategorySuggester.suggest_for([categorized]) == %{}
    end

    test "returns empty map for an empty list without querying" do
      assert CategorySuggester.suggest_for([]) == %{}
    end
  end

  describe "annotate/1" do
    test "fills the suggested_category virtual field on matches only" do
      category = category_fixture(name: "Padaria")
      transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)

      with_match = transaction_fixture(description: "Padaria São José", amount: "10.0")
      without_match = transaction_fixture(description: "OUTRA COISA", amount: "11.0")

      [a, b] = CategorySuggester.annotate([with_match, without_match])

      assert a.suggested_category == %{category_id: category.id, category_name: "Padaria"}
      assert is_nil(b.suggested_category)
    end
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/cash_lens/transactions/category_suggester_test.exs`
Expected: FAIL — `module CashLens.Transactions.CategorySuggester is not available`.

- [ ] **Step 3: Implementar**

3a. Em `lib/cash_lens/transactions/transaction.ex`, dentro do `schema "transactions"`, logo após o campo virtual `occurrence_index` existente, adicione:

```elixir
    # Virtual: on-the-fly category suggestion derived from how identical
    # (normalized) descriptions were categorized in the past. Filled by
    # CategorySuggester.annotate/1; never persisted.
    field :suggested_category, :map, virtual: true
```

(Não adicione ao `cast` do changeset — é só leitura para a UI.)

3b. Crie `lib/cash_lens/transactions/category_suggester.ex`:

```elixir
defmodule CashLens.Transactions.CategorySuggester do
  @moduledoc """
  Suggests categories for uncategorized transactions based on how identical
  descriptions (normalized via `Transaction.normalize_description/1`) were
  categorized in the past. Suggestions are computed on the fly and are never
  applied without explicit user confirmation in the UI.
  """
  import Ecto.Query

  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  @doc """
  Returns `%{transaction_id => %{category_id: ..., category_name: ...}}` for
  the uncategorized transactions whose normalized description matches
  previously categorized transactions. The most frequent category wins; ties
  break toward the most recently inserted occurrence.
  """
  def suggest_for(transactions) do
    targets =
      transactions
      |> Enum.filter(&is_nil(&1.category_id))
      |> Enum.map(&{&1.id, Transaction.normalize_description(&1.description)})

    if targets == [] do
      %{}
    else
      history = history_by_normalized_description()

      for {id, normalized} <- targets,
          suggestion = history[normalized],
          into: %{} do
        {id, suggestion}
      end
    end
  end

  @doc """
  Fills the `:suggested_category` virtual field of uncategorized transactions
  that have a suggestion. Other transactions pass through unchanged.
  """
  def annotate(transactions) do
    suggestions = suggest_for(transactions)

    Enum.map(transactions, fn tx ->
      case suggestions[tx.id] do
        nil -> tx
        suggestion -> %{tx | suggested_category: suggestion}
      end
    end)
  end

  defp history_by_normalized_description do
    from(t in Transaction,
      where: not is_nil(t.category_id),
      join: c in assoc(t, :category),
      select: {t.description, t.inserted_at, c.id, c.name}
    )
    |> Repo.all()
    |> Enum.group_by(fn {description, _at, _cat_id, _name} ->
      Transaction.normalize_description(description)
    end)
    |> Map.new(fn {normalized, rows} -> {normalized, pick_category(rows)} end)
  end

  # Most frequent category among the rows; frequency ties break toward the
  # category whose latest occurrence is most recent.
  defp pick_category(rows) do
    rows
    |> Enum.group_by(fn {_d, _at, cat_id, name} -> {cat_id, name} end)
    |> Enum.map(fn {{cat_id, name}, occurrences} ->
      latest =
        occurrences
        |> Enum.map(fn {_d, at, _i, _n} -> DateTime.to_unix(at) end)
        |> Enum.max()

      {length(occurrences), latest, %{category_id: cat_id, category_name: name}}
    end)
    |> Enum.max_by(fn {count, latest, _suggestion} -> {count, latest} end)
    |> elem(2)
  end
end
```

(`DateTime.to_unix/1` evita comparação estrutural de structs `DateTime` no desempate.)

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/cash_lens/transactions/category_suggester_test.exs`
Expected: PASS (7 testes).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/transactions/category_suggester.ex lib/cash_lens/transactions/transaction.ex test/cash_lens/transactions/category_suggester_test.exs
git commit -m "feat(transactions): CategorySuggester with history-based suggestions"
```

---

### Task 2: anotar sugestões em `list_transactions/3`

**Files:**
- Modify: `lib/cash_lens/transactions.ex`
- Test: `test/cash_lens/transactions/category_suggester_test.exs` (novo describe)

- [ ] **Step 1: Escrever o teste que falha**

Acrescente ao final de `test/cash_lens/transactions/category_suggester_test.exs` (antes do `end` final):

```elixir
  describe "integration with list_transactions/3" do
    test "rows come annotated with suggestions" do
      category = category_fixture(name: "Padaria")
      transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)
      target = transaction_fixture(description: "Padaria São José", amount: "10.0")

      rows = CashLens.Transactions.list_transactions()
      row = Enum.find(rows, &(&1.id == target.id))

      assert row.suggested_category == %{category_id: category.id, category_name: "Padaria"}
    end
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/cash_lens/transactions/category_suggester_test.exs -o "integration"`
Expected: FAIL — `row.suggested_category` é `nil` (lista ainda não anota).

- [ ] **Step 3: Implementar**

Em `lib/cash_lens/transactions.ex`:

3a. Adicione o alias junto aos existentes no topo do módulo:

```elixir
  alias CashLens.Transactions.CategorySuggester
```

3b. Em `list_transactions/3`, troque o final do pipeline:

```elixir
    |> limit(^page_size)
    |> offset(^offset)
    |> Repo.all()
```

por:

```elixir
    |> limit(^page_size)
    |> offset(^offset)
    |> Repo.all()
    |> CategorySuggester.annotate()
```

(Custo: uma query extra de histórico apenas quando a página contém linhas sem categoria — `suggest_for/1` retorna `%{}` sem query quando não há alvos.)

- [ ] **Step 4: Rodar e ver passar (+ regressões)**

Run: `mix test test/cash_lens/transactions/category_suggester_test.exs && mix test test/cash_lens/transactions_test.exs`
Expected: PASS em ambos.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/cash_lens/transactions.ex test/cash_lens/transactions/category_suggester_test.exs
git commit -m "feat(transactions): annotate listed transactions with category suggestions"
```

---

### Task 3: pill na UI + re-anotação no stream

**Files:**
- Modify: `lib/cash_lens_web/live/transaction_live/index.html.heex`
- Modify: `lib/cash_lens_web/live/transaction_live/index.ex`
- Test: `test/cash_lens_web/live/transaction_live/category_suggestion_test.exs`

- [ ] **Step 1: Escrever o teste LiveView que falha**

Crie `test/cash_lens_web/live/transaction_live/category_suggestion_test.exs`:

```elixir
defmodule CashLensWeb.TransactionLive.CategorySuggestionTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Transactions

  test "uncategorized row shows suggestion pill and clicking applies it", %{conn: conn} do
    category = category_fixture(name: "Padaria")
    transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)
    target = transaction_fixture(description: "Padaria São José", amount: "10.0")

    {:ok, live, html} = live(conn, ~p"/transactions")

    assert html =~ "Sugestão: Padaria"

    live
    |> element(
      "button[data-role='category-suggestion'][phx-value-transaction_id='#{target.id}']"
    )
    |> render_click()

    assert Transactions.get_transaction!(target.id).category_id == category.id
    refute has_element?(live, "button[data-role='category-suggestion']")
  end

  test "rows without history show no pill", %{conn: conn} do
    transaction_fixture(description: "SEM HISTORICO ALGUM")

    {:ok, live, _html} = live(conn, ~p"/transactions")

    refute has_element?(live, "button[data-role='category-suggestion']")
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/cash_lens_web/live/transaction_live/category_suggestion_test.exs`
Expected: FAIL — o HTML não contém "Sugestão: Padaria" (pill ainda não existe).

- [ ] **Step 3: Implementar o pill no heex**

Em `lib/cash_lens_web/live/transaction_live/index.html.heex`, localize a célula de categoria — o bloco `<div class="flex items-center gap-1 group/cat">` que contém o `<input type="text" placeholder={...Pendente...}>` e o botão "Limpar Categoria". **Logo após o `</div>` que fecha esse bloco** (e antes do `<div class="dropdown-content hidden fixed z-[100] ...">`), insira:

```heex
<button
  :if={is_nil(transaction.category_id) && transaction.suggested_category}
  type="button"
  data-role="category-suggestion"
  phx-click="update_category"
  phx-value-transaction_id={transaction.id}
  phx-value-category_id={transaction.suggested_category.category_id}
  class="badge badge-outline badge-info badge-sm mt-1 gap-1 cursor-pointer hover:bg-info hover:text-info-content text-[9px] font-bold"
  title="Aplicar categoria sugerida"
>
  <.icon name="hero-sparkles" class="size-3" />
  Sugestão: {transaction.suggested_category.category_name}
</button>
```

O clique reusa o evento `"update_category"` existente — sem handler novo. Isso automaticamente: aplica a categoria, mostra flash, dispara `handle_bulk_suggestion` (propõe aplicar às outras iguais) e re-insere a linha no stream (o pill some porque `category_id` deixa de ser nulo).

- [ ] **Step 4: Re-anotar a linha em `stream_update_transaction/2`**

Em `lib/cash_lens_web/live/transaction_live/index.ex`:

4a. Adicione o alias junto aos existentes no topo:

```elixir
  alias CashLens.Transactions.CategorySuggester
```

4b. Substitua a função privada `stream_update_transaction/2`:

```elixir
  defp stream_update_transaction(socket, tx) do
    tx = Transactions.get_transaction!(tx.id)

    if matches_filters?(tx, socket.assigns.filters, socket.assigns.transfer_category_id),
      do: stream_insert(socket, :transactions, tx),
      else: stream_delete(socket, :transactions, tx)
  end
```

por:

```elixir
  defp stream_update_transaction(socket, tx) do
    # Re-annotate so an uncategorized row updated for other reasons (e.g. notes)
    # keeps its suggestion pill when re-inserted into the stream.
    [tx] = CategorySuggester.annotate([Transactions.get_transaction!(tx.id)])

    if matches_filters?(tx, socket.assigns.filters, socket.assigns.transfer_category_id),
      do: stream_insert(socket, :transactions, tx),
      else: stream_delete(socket, :transactions, tx)
  end
```

- [ ] **Step 5: Rodar e ver passar (+ regressões da LiveView)**

Run: `mix test test/cash_lens_web/live/transaction_live/category_suggestion_test.exs && mix test test/cash_lens_web/live/`
Expected: PASS no novo arquivo e em toda a pasta de LiveView (nenhuma regressão).

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/cash_lens_web/live/transaction_live/index.html.heex lib/cash_lens_web/live/transaction_live/index.ex test/cash_lens_web/live/transaction_live/category_suggestion_test.exs
git commit -m "feat(transactions): suggestion pill for uncategorized rows"
```

---

### Task 4: Verificação final

**Files:** nenhum novo (só verificação).

- [ ] **Step 1: Suíte completa**

Run: `mix test`
Expected: tudo verde.

- [ ] **Step 2: Format + credo**

Run: `mix format --check-formatted && mix credo --strict`
Expected: format ok; credo sem ofensas novas (baseline atual: 0 issues).

- [ ] **Step 3: Compilação estrita**

Run: `mix compile --warnings-as-errors`
Expected: sem warnings.

- [ ] **Step 4: Smoke manual (opcional)**

Com o servidor de dev rodando, abrir /transactions com alguma transação pendente cuja descrição já tenha histórico categorizado e conferir: pill "Sugestão: X" aparece; clicar aplica e o pill some; o modal de bulk aparece se houver outras iguais sem categoria.

---

## Self-Review

**Spec coverage:**
- `CategorySuggester.suggest_for/1` (normalização, mais frequente, desempate por recência, sem histórico → sem entrada, alvos vazios → `%{}` sem query) → Task 1. ✓
- On-the-fly, sem migration → campo **virtual** (sem DDL) + annotate na listagem. ✓ (Desvio documentado do spec: assign-map não funciona com streams; o spec pedia "mapa em assign", o plano usa campo virtual — mesma semântica, compatível com streams. Registrado no header.)
- Pill "Sugestão: X [aceitar]" só em linhas sem categoria → Task 3 (`:if={is_nil(transaction.category_id) && transaction.suggested_category}`). ✓
- Aceitar usa `update_transaction_category/2` existente e dispara o fluxo de bulk → Task 3 (reuso do evento `"update_category"`). ✓
- Recalcular após categorizar / import → automático: sugestões são anotadas a cada `list_transactions` (refresh/import recarrega a lista) e a linha re-inserida no stream é re-anotada (Task 3, Step 4). ✓
- Testes do suggester + LiveView → Tasks 1–3. ✓

**Placeholder scan:** sem TBD/TODO; todo passo de código mostra código completo. ✓

**Type consistency:** `%{category_id:, category_name:}` idêntico em `suggest_for/1`, `annotate/1`, teste de integração e heex (`suggested_category.category_id` / `.category_name`). `CategorySuggester.annotate/1` recebe/retorna lista de `Transaction`. Evento `"update_category"` com `transaction_id`/`category_id` confere com o handler existente. ✓
