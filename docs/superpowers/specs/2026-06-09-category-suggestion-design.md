# Sugestão de categoria por descrição (histórico)

**Data:** 2026-06-09
**Status:** Aprovado para implementação

## Problema

Após a importação, transações que o `AutoCategorizer` não conseguiu classificar
(sem match de keyword/regra) ficam sem categoria e o usuário categoriza à mão.
Muitas dessas descrições já foram categorizadas no passado — essa informação
poderia virar uma **sugestão** para o usuário validar, acelerando a triagem.

Já existe a direção complementar: ao categorizar uma transação na UI,
`handle_bulk_suggestion` busca outras de **mesma descrição exata**
(`Transactions.list_transactions_by_description/1`, `WHERE description = ?`) sem
categoria e propõe aplicar em lote. Falta a direção "uma transação não
categorizada recebe sugestão vinda do histórico".

## Decisões de design

- **On-the-fly, sem coluna/migration.** A sugestão não é persistida; é calculada
  ao renderizar a lista. Sempre fresca (recategorizar o histórico atualiza as
  sugestões automaticamente).
- **Match normalizado.** Usa `Transaction.normalize_description/1` (colapsa
  espaços → trim → upcase → remove acentos), já existente. Casa "Padaria São José"
  com "PADARIA SAO JOSE  ".
- **Consequência:** como não há coluna normalizada nem índice, o match normalizado
  é feito **em memória** (a normalização é função Elixir, não SQL). Carrega-se o
  histórico categorizado, normaliza-se em Elixir e monta-se o mapa. Aceitável para
  um app pessoal (milhares de linhas). Upgrade futuro (YAGNI): coluna
  `normalized_description` indexada.

## Componentes

### 1. `CashLens.Transactions.CategorySuggester`

Responsabilidade única: dado um conjunto de transações **sem categoria**, devolver
sugestões a partir do histórico já categorizado.

```elixir
@spec suggest_for([Transaction.t()]) :: %{
        Ecto.UUID.t() => %{category_id: Ecto.UUID.t(), category_name: String.t()}
      }
def suggest_for(transactions)
```

Passos:
1. Coleta as descrições-alvo (das transações sem categoria) e suas formas
   normalizadas (`Transaction.normalize_description/1`). Se o conjunto está vazio,
   retorna `%{}` sem tocar no banco.
2. Carrega o histórico categorizado: transações com `category_id` não-nulo,
   pré-carregando a categoria (id, nome). (Em um app pessoal, o volume é modesto.)
3. Normaliza as descrições do histórico e agrupa por descrição normalizada. Para
   cada descrição, escolhe a categoria **mais frequente**; desempate: **mais
   recente** (maior `inserted_at`).
4. Para cada transação-alvo, casa sua descrição normalizada com o mapa do histórico
   e produz `%{tx_id => %{category_id, category_name}}`. Descrições sem histórico
   não entram no mapa (sem sugestão).

### 2. UI na lista de transações

No `transaction_live/index` (`index.ex` + `index.html.heex`):
- Calcular o mapa de sugestões para as transações **sem** `category_id` visíveis e
  guardá-lo em assign (ex.: `:category_suggestions`).
- Para cada linha sem categoria que tenha entrada no mapa, renderizar um pill
  discreto: **"Sugestão: <Categoria>"** com um botão **[aceitar]**.
- O botão dispara um evento (ex.: `accept_suggestion` com `transaction_id` +
  `category_id`) que chama o `Transactions.update_transaction_category/2` já
  existente. Isso reaproveita o fluxo atual (inclusive o `handle_bulk_suggestion`,
  que então propõe aplicar às outras iguais sem categoria).
- Nada é aplicado sem o clique — é só sugestão.

### 3. Quando recalcular

O assign `:category_suggestions` é (re)calculado:
- ao montar/listar transações;
- após `update_category` / aceitar uma sugestão (uma categorização nova muda o
  histórico);
- após uma importação concluída.

Mantém as sugestões coerentes sem persistência.

## Fluxo de dados

```
lista de transações
  ├─ uncategorized = Enum.filter(transactions, & is_nil(&1.category_id))
  ├─ suggestions = CategorySuggester.suggest_for(uncategorized)   # %{tx_id => %{...}}
  ├─ assign :category_suggestions
  └─ render: linha sem categoria + suggestion → pill "Sugestão: X [aceitar]"
        click → update_transaction_category(tx_id, category_id) (fluxo existente)
              → recalcula :category_suggestions
```

## Tratamento de erros / bordas

- Conjunto de alvos vazio → `%{}` (nenhuma query).
- Descrição sem histórico categorizado → sem sugestão (linha sem pill).
- Categoria do histórico apagada depois → o preload simplesmente não a inclui;
  como recalculamos on-the-fly, não há referência pendente.
- Empate de frequência → mais recente; empate total improvável e determinístico
  pela ordenação.

## Testes

- **CategorySuggester:**
  - Histórico "PADARIA SAO JOSE" (categoria C) faz uma transação "Padaria São José "
    sem categoria sugerir C (match normalizado, case/acentos/espaços).
  - Desempate: duas categorias para a mesma descrição → a mais frequente; com
    frequências iguais → a mais recente.
  - Sem histórico para a descrição → ausente do mapa.
  - Conjunto de alvos vazio → `%{}`.
- **LiveView (transaction_live/index):**
  - Linha sem categoria com sugestão renderiza o pill com o nome da categoria.
  - Clicar [aceitar] aplica a categoria (transação passa a ter `category_id`) e o
    pill some.

## Fora de escopo (YAGNI)

- Coluna/índice `normalized_description` (só se a base crescer muito).
- Sugerir sobrescrever transações já categorizadas.
- Persistir ou "dispensar" sugestões individualmente.
- Sugestões na importação em lote / mix task (a validação acontece na UI).
