# Design: Filtros, linhas expansíveis e coluna "Última Parcela" na tela de Parcelamentos

**Data:** 2026-06-05
**Tela alvo:** `lib/cash_lens_web/live/installment_live/index.ex` (LiveView, render inline)
**Contexto:** `lib/cash_lens/installments.ex`

## Objetivo

Melhorar a tela de Grupos de Parcelamento com:
1. Uma coluna **Última Parcela** (mês/ano do fim do parcelamento).
2. **Filtros de busca** por nome, valor total, valor da parcela e data de início.
3. **Linhas expansíveis**: ao clicar num grupo, listar as parcelas (transações vinculadas).

Sem mudança de schema.

## Estado atual

A tela exibe:
- Cards "Parcelas nos próximos meses" (`@upcoming`).
- Tabela de grupos ativos com colunas: Descrição, Valor Total, Parcela (valor por parcela = `total_amount / installments`), Progresso (`paid_count / installments` + barra), Início, botão excluir.
- `list_groups/0` carrega via `get_group_with_progress/1`, exclui finalizados (`is_finished`), ordena por `remaining_count`, aplica zebra striping por bloco de parcelas restantes.
- `InstallmentGroup`: `description_pattern`, `total_amount` (decimal, opcional), `installments` (integer), `start_date` (date), `has_many :transactions`.

## Abordagem

**Filtragem in-memory** sobre a lista de grupos ativos (conjunto pequeno; finalizados já excluídos). Mais simples que ir ao banco e suficiente para o volume. Um form acima da tabela com `phx-change="filter"` atualiza o assign `:filters`; `list_groups/1` recebe os filtros e aplica antes da ordenação/zebra.

Alternativas consideradas e descartadas:
- *Filtragem no banco (Ecto query):* desnecessária para o volume atual e exigiria mover a lógica de progresso/finalização pro SQL. YAGNI.
- *Componente de filtro genérico compartilhado com transações:* refatoração maior fora do escopo; a tela de transações tem semântica de stream/paginação diferente.

## Componentes

### 1. Coluna "Última Parcela"
- Helper de contexto `Installments.last_installment_date/1` (ou helper privado no LiveView) que calcula `add_months(start_date, installments - 1)` reusando a lógica de meses já existente em `Installments`.
- Exibição compacta **mês/ano** (`mai/26`) via `month_name/1` + ano abreviado. Nova `<th>Última Parcela</th>` e `<td>` correspondente, posicionada após "Início".

### 2. Filtros de busca
Assign `:filters` (map) com defaults vazios. Barra de filtros acima da tabela com:

| Filtro | Campo | Comportamento |
|---|---|---|
| Nome | `name` | `String.contains?` case-insensitive sobre `description_pattern` |
| Valor total | `total_amount` | busca simples: casa quando o texto digitado aparece no valor total formatado/numérico |
| Valor da parcela | `installment_amount` | idem, sobre `total_amount / installments` |
| Data início (de) | `start_from` | `start_date >= start_from` |
| Data início (até) | `start_to` | `start_date <= start_to` |

- O filtro de data início espelha o padrão `date_from`/`date_to` da tela de transações (range mín–máx, inputs `type="date"`).
- Botão **Limpar filtros** + indicador de filtros ativos (`filters_active?`).
- `handle_event("filter", %{"filters" => params}, socket)` faz merge nos filtros e recarrega via `load_data/1`.
- Filtros vazios = sem efeito (lista completa de ativos).

### 3. Linhas expansíveis
- Assign `:expanded_ids` (MapSet de ids de grupo).
- `handle_event("toggle_expand", %{"id" => id}, socket)` alterna o id no MapSet.
- A linha do grupo ganha `phx-click="toggle_expand"` + chevron (`hero-chevron-right`) que gira quando expandida. O botão excluir continua funcionando (parar propagação para não togglar ao excluir).
- Quando expandido, uma sub-`<tr>` com `colspan` lista as **parcelas** do grupo:
  - Fonte: `Installments.list_group_transactions/1` (transações com `installment_group_id == id`, ordenadas por `installment_number`).
  - Cada parcela mostra: nº parcela (`installment_number`), mês de cobrança (`date`), descrição, valor; parcelas já pagas (até `paid_count`) marcadas como "paga", as demais como "pendente".
- As parcelas são carregadas sob demanda ao expandir (ou junto no `load_data` apenas para ids expandidos) para evitar N+1 desnecessário quando nada está expandido.

## Fluxo de dados

`mount` → `load_data/1` assina `:filters` (default), `:expanded_ids` (vazio), `:groups` (filtrados), `:upcoming`.
`handle_event("filter")` → atualiza `:filters` → `load_data/1` reaplica.
`handle_event("toggle_expand")` → atualiza `:expanded_ids` → render mostra/esconde sub-linha; parcelas buscadas para ids expandidos.
`handle_event("detect_installments" | "delete" | "save")` → comportamento atual preservado, sempre via `load_data/1`.

## Tratamento de erros / bordas
- `total_amount` nulo: coluna valor da parcela e filtro tratam como "---"/sem match (comportamento atual já tolera nil).
- Grupo sem transações vinculadas ao expandir: mostrar estado vazio ("Nenhuma parcela importada ainda").
- Filtro de data com só um lado preenchido: aplica só aquele limite.

## Testes
- **Contexto** (`test/cash_lens/installments_test.exs`):
  - `last_installment_date/1` retorna `início + (parcelas-1)` meses.
  - `list_group_transactions/1` retorna parcelas ordenadas por `installment_number`.
- **LiveView** (`test/cash_lens_web/live/installment_live/index_test.exs`):
  - Filtro por nome reduz as linhas exibidas.
  - Filtros de valor total / valor da parcela / range de data início funcionam e combinam.
  - "Limpar filtros" restaura a lista.
  - Clicar numa linha expande e mostra as parcelas; clicar de novo recolhe.
  - Coluna "Última Parcela" renderiza o mês/ano correto.

## Fora de escopo
- Mudanças de schema.
- Filtros na seção "Parcelas nos próximos meses".
- Ordenação configurável por coluna (mantém o sort atual por parcelas restantes).
