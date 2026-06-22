# Previsão de fluxo de caixa (contas fixas)

**Data:** 2026-06-22
**Status:** Aprovado para implementação

## Problema

O usuário tem contas fixas (água, internet, fatura de cartão, financiamentos
etc.) que caem aproximadamente no mesmo dia todo mês, e receitas fixas
(salário) também recorrentes. Hoje não há como responder, olhando só pro
saldo atual:

1. Em que dia o saldo (das contas que não são cartão de crédito) fica
   negativo, considerando as contas fixas que ainda vão vencer?
2. Quanto vai sobrar quando a próxima receita fixa cair (ou em qualquer outra
   data escolhida)?

## Solução

Detectar contas/receitas fixas recorrentes a partir do histórico de
transações já categorizadas como tipo `fixed` (categoria já existe e já é
granular — uma categoria fixa por conta, ex: "Água", "Internet + Celular",
"Cartão de Crédito", "Salário"), guardar isso numa tabela editável
(`recurring_items`), e projetar o saldo dia a dia aplicando essas ocorrências
futuras sobre o saldo atual das contas não-cartão de crédito.

### Abordagens consideradas

- **Recomendada (escolhida):** detecção por categoria `fixed` — para cada
  categoria fixa, olha as transações históricas (contas não-cartão de
  crédito) e sugere dia do mês (mediana) e valor (mais recente). Simples,
  porque o usuário já categoriza cada conta fixa individualmente — não
  precisa de heurística de agrupamento por descrição/valor.
- **Descartada:** reaproveitar a lógica de agrupamento de parcelamentos
  (`Installments`, que agrupa por padrão de descrição + valor). Seria
  redundante dado que a categorização já é 1:1 com a conta recorrente —
  complexidade desnecessária (YAGNI).
- **Descartada:** cadastro 100% manual, sem detecção. Rejeitada porque o
  usuário quer aproveitar o histórico já categorizado como ponto de partida.

## Componentes

### 1. Schema `CashLens.Forecast.RecurringItem`

```elixir
schema "recurring_items" do
  belongs_to :category, CashLens.Categories.Category
  field :label, :string             # copiado do nome da categoria na criação
  field :day_of_month, :integer     # 1-31
  field :amount, :decimal           # sinal: positivo = receita, negativo = despesa
  field :active, :boolean, default: true
  field :manually_edited, :boolean, default: false
  timestamps()
end
```

- `category_id` é único (uma linha por categoria fixa).
- Editar `day_of_month` ou `amount` pela UI seta `manually_edited: true`.
- `active: false` pausa o item na projeção sem apagar o registro.

### 2. Detecção / sincronização — `CashLens.Forecast`

```elixir
@spec sync_all() :: %{created: integer(), updated: integer()}
@spec resync_item(RecurringItem.t()) :: {:ok, RecurringItem.t()}
```

Para cada categoria com `type == "fixed"`:

1. Busca transações dessa categoria nos últimos 6 meses, em contas com
   `is_credit_card == false`.
2. Exige **2+ ocorrências** no período — categorias com 0-1 ocorrência são
   ignoradas (evita sugerir algo que não é realmente recorrente).
3. `day_of_month` sugerido = mediana dos dias das ocorrências.
4. `amount` sugerido = valor da ocorrência mais recente.

`sync_all/0`:
- Categoria fixa **sem** `RecurringItem` ainda → cria um novo (`manually_edited: false`).
- `RecurringItem` existente com `manually_edited: false` → atualiza dia/valor
  com a sugestão recalculada.
- `RecurringItem` existente com `manually_edited: true` → **não mexe**.

`resync_item/1`:
- Recalcula dia/valor daquele item específico a partir do histórico e seta
  `manually_edited: false`, independente do estado anterior.

### 3. Cálculo da projeção — `CashLens.Forecast.Projector` (ou função no contexto)

```elixir
@spec project(horizon_days :: integer()) :: %{
  starting_balance: Decimal.t(),
  zero_date: Date.t() | nil,        # nil = não fica negativo no horizonte
  daily_balances: [%{date: Date.t(), balance: Decimal.t()}]
}
```

Algoritmo:

1. **Saldo inicial:** soma do saldo atual de todas as contas com
   `is_closed == false and is_credit_card == false` (mesma base do card
   "Saldo Atual" do painel).
2. Para cada `RecurringItem` com `active == true`, calcula a **próxima
   ocorrência**: se `day_of_month >= dia atual` (hoje incluso conta como "vai
   acontecer"), é este mês; se `day_of_month < dia atual`, mês seguinte.
   `day_of_month` maior que o número de dias do mês cai no último dia daquele
   mês (ex: 31 em abril → 30/04).
3. Gera ocorrências futuras mês a mês até cobrir `horizon_days` (padrão: 90).
4. Caminha as ocorrências em ordem cronológica, acumulando o saldo a partir
   do saldo inicial.
5. `zero_date` = primeira data em que o saldo acumulado fica negativo (`nil`
   se não acontecer dentro do horizonte).

Saldo numa data arbitrária = `starting_balance` + soma de todas as
ocorrências com `date <= data_alvo`.

### 4. Tela `/forecast` ("Previsão")

- **Card "Saldo zera em":** mostra `zero_date` formatada, ou "Não fica
  negativo nos próximos 90 dias" quando `nil`.
- **Card "Saldo em [data]":** input de data, pré-preenchido com a próxima
  ocorrência da receita fixa mais próxima (menor `day_of_month` futuro entre
  os itens com `amount > 0`); recalcula o saldo projetado ao trocar a data.
- **Tabela de itens recorrentes:** uma linha por `RecurringItem` (separando
  visualmente receitas de despesas pelo sinal), com:
  - dia do mês e valor editáveis inline (salvar seta `manually_edited: true`)
  - toggle `active`
  - botão "Ressincronizar" por linha (chama `resync_item/1`)
- **Botão "Sincronizar com Histórico"** no topo da tela (chama `sync_all/0`).

## Limitações conhecidas (aceitas para v1)

- O cálculo não cruza com transações já lançadas no mês corrente — assume
  que, se a data do `day_of_month` ainda não chegou, a conta ainda não foi
  paga. Pagamentos antecipados deixam a projeção levemente otimista perto da
  virada do mês.
- Só considera contas fixas (não há média de gastos variáveis no cálculo).
- Categorias fixas com menos de 2 ocorrências no histórico não são
  sugeridas automaticamente — precisam ser cadastradas manualmente se o
  usuário quiser incluí-las desde já.

## Testes

- Detecção: categoria com 1 ocorrência não é sugerida; com 2+ é sugerida com
  mediana/valor corretos; ignora transações de contas com `is_credit_card`.
- `sync_all/0`: cria itens novos, atualiza só os não editados manualmente,
  preserva os `manually_edited: true`.
- `resync_item/1`: força atualização e reseta `manually_edited` para `false`.
- Projeção: próxima ocorrência calculada corretamente quando o dia já passou
  vs. ainda não passou no mês corrente; clamp de dia inválido (31 em mês de
  30 dias / fevereiro); `zero_date` correto incluindo o caso de não zerar no
  horizonte; soma até uma data arbitrária bate com a soma manual das
  ocorrências esperadas.
- Itens `active: false` não entram na projeção.

## Fora de escopo (YAGNI)

- Média de gastos variáveis na projeção.
- Detecção por padrão de descrição (fora de categorias `fixed`).
- Múltiplos cenários/simulações salvas (ex: "e se eu cancelar a Netflix").
- Notificações/alertas quando o saldo previsto fica negativo.
