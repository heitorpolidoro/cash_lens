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
@tolerance_days 15

@spec match_batch([Transaction.t()]) :: {:ok, parent_id} | :no_match | :not_credit_card_batch
@spec match_payment(Transaction.t()) :: {:ok, count_linked} | :no_match | :not_credit_card_category
```

- `match_batch/1`: recebe o lote recém-inserido pelo `Ingestor` (mesma
  forma que `TransferMatcher.match_transfers/1` recebe hoje). Filtra só
  transações de contas `is_credit_card: true` sem `parent_transaction_id`.
  Agrupa por `account_id` (um lote normalmente é uma conta só). Soma o
  grupo, procura uma transação com categoria `"Cartão de Crédito"`,
  `amount == -soma`, sem filhas ainda, com `date` dentro de
  `@tolerance_days` da data mais recente do lote (desempate: menor
  diferença de dias). Se achar, seta `parent_transaction_id` em todas as
  transações do lote via `update_all`.
- `match_payment/1`: direção inversa — uma transação acabou de virar
  `"Cartão de Crédito"` (regra ou edição manual). Procura, entre as
  transações de contas de cartão sem pai, um subconjunto **= todas as
  transações de uma mesma data de importação ainda não vinculadas a nenhum
  pai** (aproximação: agrupa órfãs por `account_id` e checa se a soma total
  de órfãs daquela conta bate com o valor do pagamento; não tenta
  combinações parciais). Se bater, vincula.
- Chamado no pipeline de import (`Ingestor.process_entries/3`, junto do
  `TransferMatcher.match_transfers/1`) e em qualquer caminho que categorize
  uma transação como `"Cartão de Crédito"` (`TransferRuleApplier`,
  `update_transaction_category/2`, edição manual de categoria).

### 5. Migração de dados históricos

Script/migration única (`Mix.Tasks` ou migration de dados) que, para cada
par hoje ligado por `transfer_key` onde uma das pontas pertence a uma conta
`is_credit_card: true`:

1. Recategoriza a transação do lado pagador (conta não-cartão) para
   `"Cartão de Crédito"`, limpa `transfer_key`.
2. Apaga a transação-espelho fictícia do lado da conta do cartão (ela não
   é uma compra real).
3. Roda `CreditCardMatcher.match_payment/1` na transação recategorizada
   para tentar religar as transações reais da fatura daquele período.
4. Casos sem match viram entradas naturais na tela de alerta (não tratados
   especialmente pela migration).

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

(query única, sem N+1 — ver seção "dúvida" da conversa). O filtro
`c.slug not in ["initial_value", "transfer"]` continua existindo para os
casos de transferência normal entre contas (não-cartão); `"transfer"` não
precisa incluir mais `"cartao-de-credito"` na lista de exclusão porque a
exclusão por "tem filhas" já cobre o caso — e se uma transação
`"Cartão de Crédito"` ficar sem filhas (divergência ainda não resolvida ou
pagamento avulso sem fatura importada), ela aparece no gráfico como
gasto da categoria "Cartão de Crédito" mesmo, o que é o comportamento
correto nesse caso (não há detalhe melhor disponível).

## Fora de escopo (YAGNI)

- UI genérica de "dividir transação em N partes" — o recurso é específico
  para fatura de cartão por enquanto.
- Esconder/agrupar visualmente as transações-filhas na lista principal de
  transações (`/transactions`). Elas continuam aparecendo normalmente; só
  ganham um indicador visual de vínculo.
- Matching por subset-sum parcial em `match_payment/1` — assume que todas
  as órfãs de uma conta de cartão pertencem à mesma fatura pendente.

## Testes

- `CreditCardMatcher.match_batch/1`: soma bate e data dentro da tolerância
  → vincula; soma não bate → sem match; mais de uma transação
  `"Cartão de Crédito"` candidata → escolhe a de menor diferença de dias.
- `CreditCardMatcher.match_payment/1`: mesma cobertura, direção inversa.
- `TransferRuleApplier`: regra com destino `is_credit_card: true` categoriza
  como `"Cartão de Crédito"` e não cria espelho; regra com destino normal
  mantém comportamento atual.
- Migração de dados: par antigo (`transfer_key` + cartão) vira pagador
  recategorizado + filhas religadas quando a soma bate; espelho fictício
  removido.
- `get_month_category_breakdown/2` / `get_historical_category_summary/1`:
  transação com filhas não aparece; filhas aparecem com suas próprias
  categorias; transação "Cartão de Crédito" sem filhas aparece normalmente.
- Tela `/credit_card_links`: lote órfão aparece em "Sem Pai Encontrado";
  par com soma divergente aparece em "Vinculados com Divergência"; vínculo
  manual e desvínculo funcionam.
