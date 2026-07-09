# Fatura de cartão na previsão de fluxo de caixa

**Data:** 2026-07-07
**Status:** Aprovado (brainstorming)

## Problema

A previsão de saldo (`CashLens.Forecast`) hoje trata "Cartão de Crédito" como
um item recorrente igual a qualquer conta fixa (categoria `fixed`, sugestão =
valor da fatura mais recente). Isso ignora duas coisas que agora sabemos com
certeza:

1. **Parcelamentos** (`installment_groups`) têm valor e mês exatos — não
   precisam de estimativa.
2. **Faturas já fechadas e importadas** (`credit_card_statements`, com o
   ciclo de fechamento do Projeto anterior) têm `total_a_pagar` e `due_date`
   reais quando ainda não pagas — mais certo que qualquer estimativa.

## Objetivo

Substituir o item recorrente genérico de cartão por uma ocorrência mensal por
cartão, calculada a partir da fonte mais certa disponível: boleto real
quando existe, senão parcelas conhecidas + o mesmo critério de estimativa
já usado pelas outras contas fixas (`suggest_for_category/1`: valor da
ocorrência mais recente numa janela de `@history_months` = 6 meses).

## Não-objetivos (YAGNI)

- Editar a estimativa de cartão na tela (os itens recorrentes continuam
  editáveis; a fatura de cartão é sempre derivada, sem edição manual).
- Prever parcelamentos além dos `installment_groups` já detectados.
- Cartões sem ciclo configurado (`closing_day`/`due_day` nil): ficam de fora
  da previsão, como hoje ficariam sem estimativa por falta de data confiável.

## Fonte das ocorrências (por cartão, no ciclo)

Para cada conta `is_credit_card` com `closing_day` e `due_day` configurados,
gera-se **uma ocorrência por mês do horizonte**, com `date` = a data de
vencimento daquele mês e `amount` negativo (saída), na moeda:

1. **Boleto real** — existe uma fatura (`credit_card_statements`) daquela
   conta, com `due_date` naquele mês, **não paga** (`payment_transaction_id`
   nil): usa `total_a_pagar` (fallback: soma das linhas se `total_a_pagar`
   for nil) e o `due_date` real da fatura.
2. **Estimada** — não há fatura importada para aquele mês:
   `gasto_variável_recente + Σ parcelas do mês`, onde:
   - **`parcelas do mês`** = soma das parcelas de `installment_groups`
     cujas transações pertencem à conta do cartão E cujo mês de parcela
     (mesmo cálculo de `Installments.upcoming_installments/1`) coincide com
     o mês projetado.
   - **`gasto_variável_recente`** = `total_a_pagar (ou soma dos itens) −
     Σ parcelas` da fatura-boleto **mais recente** da conta dentro dos
     últimos `@history_months` (6 meses, a mesma constante de
     `CashLens.Forecast`). Sem fatura-boleto nessa janela → sem estimativa
     para esse cartão (equivalente a `:insufficient_history`).
3. **Fatura paga** não gera ocorrência (o débito já saiu do saldo das
   contas correntes ao ser pago).

## Integração no motor de projeção

- Nenhum `recurring_item` é criado para categorias de cartão de crédito
  (a fonte é sempre dinâmica, não editável). Hoje não existe nenhum item
  recorrente de cartão no banco (confirmado), então não há dado a migrar;
  como salvaguarda, `sync_all/0` passa a pular/ignorar categorias de cartão
  de crédito ao detectar itens fixos, para que um nunca seja criado.
- `CashLens.Forecast.project/1` passa a somar duas fontes de ocorrências:
  os itens recorrentes ativos (como hoje) e as ocorrências de fatura de
  cartão (novo: `CashLens.Forecast.card_occurrences(today, horizon_end)`),
  antes de ordenar por data e acumular o saldo corrido. O saldo inicial
  continua sendo `current_balance()` das contas não-cartão de crédito
  (inalterado).
- Cada ocorrência de fatura carrega `label` (nome do cartão), `date`,
  `amount` e uma origem (`:boleto` ou `:estimado`) para a UI distinguir.

## UI

Na tela `/forecast`, a lista de ocorrências ganha as entradas de fatura de
cartão misturadas por data com os itens recorrentes, mostrando o rótulo do
cartão e um selo de origem ("Boleto" ou "Estimado"). Nenhuma tela nova.

## Testes

- **Boleto real vence no horizonte, não pago** → ocorrência usa
  `total_a_pagar`/`due_date` exatos; se pago, nenhuma ocorrência.
- **Sem boleto no mês, com parcelas** → estimativa = gasto variável recente
  + soma das parcelas daquele mês; parcelas não contam duas vezes.
- **Sem boleto no mês, sem parcelas** → estimativa = só o gasto variável
  recente.
- **Sem fatura-boleto na janela de 6 meses** → sem ocorrência para o
  cartão naquele mês (equivalente a `:insufficient_history`).
- **Cartão sem ciclo configurado** → nenhuma ocorrência gerada, sem erro.
- **`project/1`** combina itens recorrentes + ocorrências de cartão,
  ordenado por data, saldo corrido correto, `zero_date` inalterado na
  lógica.
- **LiveView**: ocorrência de cartão aparece na lista com o rótulo e a
  origem.

## Arquivos

- `lib/cash_lens/forecast.ex` — `card_occurrences/2` (ou módulo dedicado
  `CashLens.Forecast.CardOccurrences` se o arquivo crescer demais), wiring
  em `project/1`.
- `lib/cash_lens/installments.ex` — pode expor um helper reaproveitável
  para "parcelas de uma conta num mês" se a lógica de
  `month_installment_total/parcel_due_in_month?` não for diretamente
  reaproveitável por já filtrar por todos os grupos.
- `lib/cash_lens_web/live/forecast_live/index.ex` — selo de origem na
  renderização das ocorrências.
- `sync_all/0` (em `lib/cash_lens/forecast.ex`) — excluir categorias de
  cartão de crédito da detecção, como salvaguarda contra duplicação.
- Testes correspondentes em `test/cash_lens/forecast_test.exs` e
  `test/cash_lens_web/live/forecast_live_test.exs`.
