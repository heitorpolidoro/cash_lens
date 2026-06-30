# Sub-transações para faturas de cartão de crédito

**Data:** 2026-06-30
**Status:** Aprovado para implementação

## Problema

Hoje, pagar a fatura do cartão gera uma "transferência" (categoria
`transfer`) entre a conta pagadora e a conta `is_credit_card: true`: o
`TransferRuleApplier` cria uma transação-espelho artificial na conta do
cartão e o `TransferMatcher` liga o par por `transfer_key`. Isso tem dois
problemas:

1. A categoria `transfer` esconde *o quê* foi gasto no cartão — o gráfico de
   gastos por categoria não enxerga as compras reais (Uber, iFood etc), só o
   valor total da fatura como "transferência".
2. A transação-espelho na conta do cartão é fictícia (não existe no extrato
   real do banco), só serve para o `TransferMatcher` conseguir casar 1:1.

## Solução

Não removemos contas `is_credit_card` — elas continuam recebendo a
importação real da fatura (PDF/CSV/OFX). A mudança é:

1. O pagamento da fatura (transação na conta pagadora) passa a ser
   categorizado como **"Cartão de Crédito"** em vez de `transfer`, sem
   espelho fictício.
2. As transações reais da fatura (uma por compra, já na conta do cartão)
   viram **filhas** dessa transação de pagamento via um novo campo
   `parent_transaction_id`.
3. O vínculo pai/filhas é casado automaticamente por **soma do lote
   importado == valor do pagamento** e **data próxima**, com tela manual de
   fallback e alerta de divergência.
4. Gráficos de gasto por categoria passam a ignorar qualquer transação que
   tenha filhas — assim quem aparece é a categoria real de cada compra, não
   "Cartão de Crédito".

### Abordagens consideradas

- **Recomendada (escolhida):** `parent_transaction_id` auto-referenciado em
  `transactions` + matching automático por soma/data, reaproveitando o
  padrão já existente do `TransferMatcher`/`TransferRuleApplier`. Mudança
  cirúrgica, sem mexer no conceito de conta.
- **Descartada:** remover de vez o conceito de conta `is_credit_card` e
  importar a fatura "solta" (sem account_id) ou direto na conta pagadora.
  Rejeitada pelo usuário — faz sentido manter a conta do cartão como destino
  real da importação da fatura.
- **Descartada:** matching por subset-sum sobre todas as transações órfãs
  da conta do cartão (sem respeitar o lote de importação). Mais flexível,
  mas ambíguo (qual subconjunto pertence a qual fatura) e bem mais
  complexo. O agrupamento por lote de importação já é suficiente, porque
  cada importação de fatura é uma operação só.

## Componentes

### 1. Schema — `transactions.parent_transaction_id`

```elixir
field :parent_transaction_id, :binary_id  # FK self, on_delete: :nilify_all
```

- Índice em `parent_transaction_id`.
- Migration adiciona a coluna + FK + índice. Sem mudança em `accounts`.
- `Transaction.changeset/2` passa a aceitar `:parent_transaction_id` no
  `cast`. Não entra no `dedup_key`/`fingerprint` (não é parte da identidade
  da transação).

### 2. Categoria seed `"Cartão de Crédito"`

- Slug `cartao-de-credito`, `type: "variable"`, sem `default_reimbursable`.
- Criada via seed/migration de dados, igual ao padrão da categoria
  `transfer` já existente.

### 3. `TransferRuleApplier` — comportamento por tipo de destino

Em `apply_rules_to_transaction/3`, ao encontrar uma regra cujo
`destination_account.is_credit_card == true`:

- Categoriza a transação de origem como `"Cartão de Crédito"` (em vez de
  `"transfer"`).
- **Não cria transação-espelho**, independente do valor de `create_mirror`
  na regra (mirror deixa de fazer sentido para esse destino).
- Dispara `CreditCardMatcher.match_payment/1` na transação recém-categorizada,
  tentando achar um lote órfão na conta do cartão que bata por soma/data.

Quando o destino **não** é cartão, comportamento inalterado (fluxo de
`transfer` atual).

### 4. `CashLens.Transactions.CreditCardMatcher` (novo módulo)

Espelha o `TransferMatcher`, mas casando **soma de N filhas == valor do
pai**, não 1:1.

```elixir
@tolerance_days 5

@spec match_batch([Transaction.t()]) :: {:ok, parent_id} | :no_match | :ambiguous | :not_credit_card_batch
@spec match_payment(Transaction.t()) :: {:ok, count_linked} | :no_match | :multiple_orphan_batches | :not_credit_card_category
```

- **Identidade de lote sem mudança de schema**: o `Ingestor` já insere cada
  importação com um único timestamp `inserted_at` compartilhado por todas
  as linhas daquele arquivo (`now = DateTime.utc_now() |> DateTime.truncate(:second)`,
  calculado uma vez por chamada — ver `prepare_entries/2`). Isso é
  suficiente para reconstruir "lote" sem precisar de um campo novo:
  agrupar transações órfãs de uma conta de cartão por `inserted_at` dá os
  lotes de importação reais.
- `match_batch/1`: recebe o lote recém-inserido pelo `Ingestor` (mesma
  forma que `TransferMatcher.match_transfers/1` recebe hoje). Filtra só
  transações de contas `is_credit_card: true` sem `parent_transaction_id`.
  Agrupa por `account_id` (um lote normalmente é uma conta só). Soma o
  grupo, procura transações com categoria `"Cartão de Crédito"`,
  `amount == -soma`, sem filhas ainda, com `date` dentro de
  `@tolerance_days` (±5 dias) da data mais recente do lote. Desempate por
  menor diferença de dias — **se houver empate exato entre 2+ candidatos,
  recusa o auto-match** (retorna `:ambiguous`) em vez de escolher
  arbitrariamente; o lote cai na tela manual. Se achar um único candidato
  sem empate, seta `parent_transaction_id` em todas as transações do lote
  via `update_all`.
- `match_payment/1`: direção inversa — uma transação acabou de virar
  `"Cartão de Crédito"`. Agrupa as transações órfãs (sem
  `parent_transaction_id`) da conta de cartão correspondente por
  `inserted_at` (= lote de importação real, não soma cega da conta
  inteira). **Se houver mais de um lote órfão pendente**, recusa o
  auto-match (retorna `:multiple_orphan_batches`) — não tenta decidir
  qual lote (ou combinação) pertence a este pagamento; o caso cai
  inteiramente na tela manual, que mostra todos os lotes órfãos daquela
  conta para o usuário escolher/agrupar. Só tenta o match automático
  quando existe exatamente 1 lote órfão, testando se a soma desse lote
  bate com o valor do pagamento dentro da tolerância de data.
- Chamado no pipeline de import (`Ingestor.process_entries/3`, junto do
  `TransferMatcher.match_transfers/1`); em `TransferRuleApplier` logo após
  categorizar como `"Cartão de Crédito"`; em `update_transaction_category/2`
  e em qualquer edição manual de categoria — **com guard explícito**: só
  dispara quando `category_id` novo é o da categoria `"Cartão de Crédito"`,
  espelhando o guard que já existe hoje para `"transfer"` em
  `maybe_apply_transfer_matching/2`. Não roda incondicionalmente em toda
  troca de categoria.
- `Transactions.reapply_transfer_rules/0` (botão "Reaplicar Regras" da
  tela de transferências) passa também a rodar `CreditCardMatcher.match_payment/1`
  sobre transações `"Cartão de Crédito"` sem filhas e a reavaliar lotes
  órfãos — dá ao usuário uma forma de re-tentar o match automático depois
  de resolver manualmente uma ambiguidade (ex: depois de linkar um dos
  lotes órfãos antigos, o outro pode passar a bater sozinho).

### 5. Migração de dados históricos

Script/migration única (`Mix.Tasks` ou migration de dados) que age **apenas**
sobre pares hoje ligados por `transfer_key` cuja origem corresponde a uma
`TransferRule` existente e ativa (`source_account_id` = conta pagadora,
`destination_account_id` = conta `is_credit_card: true`, `create_mirror:
true`) — esse é exatamente o caminho automatizado que cria a
transação-espelho fictícia, então é o único caso em que apagar o lado-cartão
do par é seguro.

Para cada par dentro desse critério:

1. Recategoriza a transação do lado pagador (conta não-cartão) para
   `"Cartão de Crédito"`, limpa `transfer_key`.
2. Apaga a transação-espelho fictícia do lado da conta do cartão (ela não
   é uma compra real — está coberta pelo critério acima, então sabemos que
   foi criada automaticamente).
3. Roda `CreditCardMatcher.match_payment/1` na transação recategorizada
   para tentar religar as transações reais da fatura daquele período.
4. Casos sem match (inclusive `:multiple_orphan_batches`) viram entradas
   naturais na tela de alerta (não tratados especialmente pela migration).

Pares `transfer_key` envolvendo conta de cartão que **não** se encaixam
nesse critério (vínculo manual via `/transfers`, ou regra sem
`create_mirror`) **não são tocados automaticamente** — a migration gera um
relatório (log) com a contagem e os IDs desses pares ambíguos para revisão
manual do usuário. Roda dentro de uma transação de banco, com log dos IDs
afetados antes de cada delete (auditoria/rollback) e um sanity check (não
prosseguir se o número de deletes for anormalmente alto vs. esperado).

### 6. Tela `/credit_card_links` ("Cartão de Crédito")

Mesmo padrão visual de `/transfers` (`TransferLive.Index`):

- **Pares Sugeridos**: lotes batendo automaticamente, aguardando
  confirmação manual (mesmo fluxo de "Confirmar"/"Confirmar Todos").
- **Sem Pai Encontrado**: lotes órfãos na conta do cartão sem pagamento
  correspondente — vínculo manual (reaproveita o padrão do
  `TransferLinkComponent`, adaptado para selecionar N filhas em vez de 1
  par).
- **Vinculados com Divergência** *(o alerta pedido)*: pares já vinculados
  onde `soma(filhas) != abs(valor do pai)`. Mostra a diferença em destaque
  e permite desvincular para corrigir manualmente.
- **Vinculados OK**: pares corretos, com opção de desvincular.

### 7. Gráficos de gasto por categoria

`get_month_category_breakdown/2` e `query_historical_category_totals/0`
(em `CashLens.Transactions`) passam a excluir transações com filhas:

```elixir
where: not exists(
  from c in Transaction, where: c.parent_transaction_id == parent_as(:t)
)
```

(query única, sem N+1 — ver seção "dúvida" da conversa; índice simples em
`parent_transaction_id` é suficiente para o anti-join). O filtro
`c.slug not in ["initial_value", "transfer"]` continua existindo para os
casos de transferência normal entre contas (não-cartão); `"transfer"` não
precisa incluir mais `"cartao-de-credito"` na lista de exclusão porque a
exclusão por "tem filhas" já cobre o caso — e se uma transação
`"Cartão de Crédito"` ficar sem filhas (divergência ainda não resolvida ou
pagamento avulso sem fatura importada), ela aparece no gráfico como
gasto da categoria "Cartão de Crédito" mesmo, o que é o comportamento
correto nesse caso (não há detalhe melhor disponível).

### 8. Totais financeiros gerais — evitar dupla contagem

Sem tratamento, o pagamento da fatura (categoria `"Cartão de Crédito"`,
saindo da conta pagadora) e cada compra individual da fatura (categorias
reais, saindo da conta do cartão) contariam **ambos** como gasto do mesmo
período em `get_monthly_summary/2`, `get_filtered_summary/1` e
`get_historical_summary/1` — dinheiro contado duas vezes.

Tratamento: mesmo padrão já usado hoje para `"transfer"`.
`exclude_transfer_category/1` (e os pontos equivalentes de filtro de
categoria nessas três funções) passam a excluir também o slug
`cartao-de-credito`, exatamente como excluem `"transfer"` hoje. As compras-
filhas continuam contando normalmente nesses totais, com suas categorias
reais — só a transação-pai "Cartão de Crédito" fica de fora, igual ao
gráfico de categoria.

## Fora de escopo (YAGNI)

- UI genérica de "dividir transação em N partes" — o recurso é específico
  para fatura de cartão por enquanto.
- Esconder/agrupar visualmente as transações-filhas na lista principal de
  transações (`/transactions`). Elas continuam aparecendo normalmente; só
  ganham um indicador visual de vínculo.
- Matching por subset-sum/combinação entre múltiplos lotes órfãos
  simultâneos em `match_payment/1` — quando há mais de um lote pendente,
  o sistema deliberadamente não tenta adivinhar qual (ou quais)
  pertence(m) ao pagamento; cai sempre na tela manual (`:multiple_orphan_batches`).
- Pagamento parcial de fatura (valor menor que a soma da fatura): não há
  match automático por soma exata; cai naturalmente na tela manual como
  qualquer outro caso sem correspondência exata.

## Testes

- `CreditCardMatcher.match_batch/1`: soma bate e data dentro da tolerância
  (±5 dias) → vincula; soma não bate → `:no_match`; lote com estorno
  positivo misturado a compras negativas, soma líquida bate → vincula;
  duas transações `"Cartão de Crédito"` candidatas com a mesma diferença
  de dias (empate exato) → `:ambiguous`, não vincula nada.
- `CreditCardMatcher.match_payment/1`: exatamente 1 lote órfão e soma bate
  → vincula; 2+ lotes órfãos pendentes na mesma conta de cartão →
  `:multiple_orphan_batches`, não vincula nenhum (mesmo que a soma de um
  deles bata sozinha); lotes identificados corretamente por `inserted_at`
  compartilhado (duas importações em momentos diferentes não se misturam).
- `TransferRuleApplier`: regra com destino `is_credit_card: true` categoriza
  como `"Cartão de Crédito"` e não cria espelho; regra com destino normal
  mantém comportamento atual (transfer + mirror quando `create_mirror: true`).
- Guard de categoria: `update_transaction_category/2` só dispara
  `CreditCardMatcher` quando a nova categoria é "Cartão de Crédito"; trocar
  para qualquer outra categoria não roda o matcher.
- `reapply_transfer_rules/0`: também re-tenta `CreditCardMatcher.match_payment/1`
  sobre transações "Cartão de Crédito" sem filhas.
- Migração de dados: par antigo coberto por `TransferRule` ativa
  (`create_mirror: true`, destino cartão) vira pagador recategorizado +
  filhas religadas quando a soma bate; espelho fictício removido. Par
  `transfer_key` envolvendo cartão **fora** desse critério (vínculo manual,
  ou regra sem `create_mirror`) não é tocado e aparece no relatório de
  pares ambíguos.
- `get_month_category_breakdown/2` / `get_historical_category_summary/1`:
  transação com filhas não aparece; filhas aparecem com suas próprias
  categorias; transação "Cartão de Crédito" sem filhas aparece normalmente.
- `get_monthly_summary/2` / `get_filtered_summary/1` / `get_historical_summary/1`:
  transação "Cartão de Crédito" não conta nos totais; compras-filhas
  continuam contando normalmente com suas categorias reais — sem dupla
  contagem entre pagamento e compras no mesmo período.
- Tela `/credit_card_links`: lote órfão aparece em "Sem Pai Encontrado";
  par com soma divergente aparece em "Vinculados com Divergência"; caso
  `:multiple_orphan_batches`/`:ambiguous` aparece para resolução manual;
  vínculo manual e desvínculo funcionam.
- Editar valor/data/descrição de uma transação-filha não derruba o vínculo
  com o pai (`parent_transaction_id` não é tocado pelo changeset a menos
  que explicitamente alterado); reimportar a mesma fatura depois que as
  filhas já têm pai não perde o vínculo (`on_conflict: :nothing` preserva
  a linha existente).
