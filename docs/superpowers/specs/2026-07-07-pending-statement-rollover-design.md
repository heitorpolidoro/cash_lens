# Projeto B — Fatura pendente (não-boleto) + absorção no boleto seguinte

**Data:** 2026-07-07
**Status:** Aprovado (brainstorming)

## Problema

Faturas de cartão pequenas demais não geram boleto: o banco cobra o valor
junto com o boleto do mês seguinte. Hoje essas "prévias" aparecem como faturas
**abertas** que nunca fecham, confundindo a tela. Exemplo real (Amazon): a
fatura de Fev (total R$ 3,40, multa + juros) não gerou boleto e foi cobrada em
Março — e de fato `total(Março) 56,53 − |itens de Março| 53,13 = 3,40`.

Com o Projeto A concluído (Ourocard agora em TXT, sempre com Vencimento), o
sinal "fatura de cartão **sem Vencimento** = não-boleto" vale **uniforme** para
todos os cartões. As não-boleto restantes são as PDFs pequenas do Bradesco
(Amazon/Amex).

## Objetivo

Marcar faturas sem Vencimento como **pendentes**, e quando o **boleto seguinte**
é importado, se as contas fecharem exatamente, **absorver** a pendente nele
("incorporada em [Mmm/YY]") e propagar o vínculo de pagamento.

## Não-objetivos (YAGNI)

- Distinguir automaticamente "fatura em aberto / mês corrente" de "não-boleto
  pequena" (ambas sem Vencimento). O usuário resolve não importando faturas em
  aberto. Detecção automática fica para depois.
- Toleância de arredondamento: casamento é **exato** (centavo).
- Subset-sum de pendentes: soma **todas** as pendentes da conta, tudo-ou-nada.

## Modelo de dados

Nova coluna em `credit_card_statements`:

- `absorbed_by_statement_id` — `binary_id`, FK nullable → `credit_card_statements`
  (`on_delete: :nilify_all`). Preenchida = fatura foi incorporada nesse boleto.

## Status (derivado)

`statement_status/2` (ou uma função dedicada que o consome) passa a distinguir:

- **`:absorbed`** — `absorbed_by_statement_id` preenchido. Rótulo
  "Incorporada em [Mmm/YY do boleto]". Tem prioridade sobre os demais.
- **`:pending`** — `due_date` nil, não-absorvida, sem pagamento. Não-boleto
  aguardando o boleto seguinte.
- **`:linked` / `:divergent` / `:open`** — inalterados, para faturas-boleto
  (com Vencimento) conforme já implementado.

## Lógica de absorção

### Fórmula (exata)

Uma coleção de pendentes P da conta é absorvível por um boleto B quando:

```
B.total_a_pagar − |soma dos itens de B| == Σ P.total_a_pagar
```

- Usa o **`total_a_pagar`** de cada pendente (o valor que rola pra frente),
  NÃO a soma dos itens dela (que inclui pagamento-recebido/saldo).
- `|soma dos itens de B|` = valor absoluto da soma das transações de B
  (`import_batch_id == B.id`). Para os boletos Bradesco que geram pendentes,
  os itens são compras → a conta fecha. Se um boleto trouxer crédito nos itens
  e a conta não fechar, simplesmente **não absorve** (cai pro manual).
- Casamento **exato** (`Decimal.equal?`), sem tolerância.
- **Tudo-ou-nada:** considera TODAS as pendentes elegíveis da conta juntas; se a
  soma não fecha, não absorve nenhuma.

### Gatilho no import

Em `Ingestor` / `CreditCards`, ao criar um **boleto** B (fatura com
`due_date` não-nil) numa conta `is_credit_card`, na ordem:

1. cria a fatura B e carimba as transações de B (`import_batch_id`);
2. **absorve pendentes:** junta as pendentes P da conta (due_date nil,
   `absorbed_by_statement_id` nil) **anteriores a B** — uma pendente só rola
   pra frente, nunca pra trás. Ordena por `competencia` com fallback em
   `inserted_at` (a pendente Amazon 0,33 não tem competência, pois não tem
   transações datadas → ordena pelo `inserted_at`). Testa a fórmula; se bate,
   seta `P.absorbed_by_statement_id = B.id` para cada P. Pendente sem boleto
   seguinte que feche a conta permanece `:pending`;
3. `Matcher.auto_link(B, …)` — como as pendentes já foram absorvidas por B, o
   vínculo de pagamento (passo seguinte) cobre as transações delas também.

Faturas **sem** Vencimento (pendentes) não disparam absorção nem auto-link;
ficam `:pending`.

### Pagamento

- `CreditCards.link_payment(B, payment_id)` passa a setar `parent_transaction_id`
  nas transações de B **e** nas transações de toda fatura `absorbed_by B`.
- `CreditCards.unlink_payment(B)` reverte ambas.

Isso mantém a simetria: pagar o boleto marca como pagas também as transações
das pendentes incorporadas nele.

## Reconciliação retroativa

Mix task `cash_lens.reconcile_pending_statements`:

- Para cada conta de cartão, itera os **boletos** em ordem cronológica
  (competência/vencimento); para cada boleto B, junta as pendentes ainda
  não-absorvidas anteriores a B, testa a fórmula, e absorve as que batem.
- Se B já está vinculado a um pagamento, ao absorver P **propaga o vínculo**:
  as transações de P recebem `parent_transaction_id` do pagamento de B.
- Idempotente: reprocessar não altera nada além de re-confirmar (pendentes já
  absorvidas são puladas).
- Roda uma vez após o deploy (dados atuais: Amazon 3,40/0,00/0,33; Amex 0,00).

## UI (`CreditCardStatementLive`)

- **Overview:**
  - `:pending` → badge `⏳ Pendente` (âmbar/neutro, distinto de "Aberta") com
    dica "possível cobrança na próxima fatura".
  - `:absorbed` → linha discreta (cinza), rótulo "Incorporada em [Mmm/YY]";
    sai da leitura de "abertas".
- **Detalhe:**
  - `:pending` → mostra a dica.
  - `:absorbed` → "Incorporada na fatura [Mmm/YY]" com link (`?id=` do boleto).
- Reutiliza `format_competencia/1` e o mapeamento de badges existente.

## Testes

- **Status:** `:pending` (due_date nil, não-absorvida), `:absorbed`
  (absorbed_by preenchido), prioridade de `:absorbed`.
- **Absorção (fórmula):** absorve quando `B.total − |itens B| == Σ pendentes`;
  não absorve quando difere de 1 centavo; tudo-ou-nada com 2 pendentes.
- **Pagamento:** `link_payment(B)` parenteia transações de B e das absorvidas;
  `unlink_payment(B)` reverte.
- **Import:** importar um boleto após uma pendente elegível a absorve; boleto
  sem match não absorve; fatura sem Vencimento vira `:pending`.
- **Reconciliação:** absorve pendentes existentes nos boletos certos, propaga
  pagamento quando o boleto já está vinculado, idempotente.
- **LiveView:** overview mostra badges pendente/incorporada; detalhe linka a
  fatura absorvente.

## Arquivos

- Migration: adiciona `absorbed_by_statement_id` a `credit_card_statements`.
- `lib/cash_lens/credit_cards/statement.ex` — campo + cast + assoc.
- `lib/cash_lens/credit_cards.ex` — status `:pending`/`:absorbed`, função de
  absorção, `link_payment`/`unlink_payment` estendidos, helper de reconciliação.
- `lib/cash_lens/parsers/ingestor.ex` — dispara absorção na criação de boleto.
- `lib/mix/tasks/cash_lens.reconcile_pending_statements.ex` — task retroativa.
- `lib/cash_lens_web/live/credit_card_statement_live/index.ex` — badges + rótulos.
- Testes correspondentes.
