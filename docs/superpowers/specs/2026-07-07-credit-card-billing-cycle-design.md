# Ciclo de fechamento do cartão

**Data:** 2026-07-07
**Status:** Aprovado (brainstorming)

## Problema

A competência de uma fatura **sem Vencimento** (não-boleto) é hoje chutada pela
data da transação mais recente (`CreditCards.competencia_from/2`). Isso erra: o
`2026-02-Amazon.pdf` (fatura de fevereiro) só tem lançamentos de janeiro, então
derivou **Jan/26**, quando o correto é **Fev/26**. O sinal confiável do mês da
fatura é o **ciclo de cobrança** do cartão (fechamento + vencimento), não as
datas das compras.

## Objetivo

Configurar o ciclo (dia de fechamento + dia de vencimento) em cada conta de
cartão, estimando dos boletos e deixando o usuário confirmar; derivar a
competência a partir do ciclo (corrigindo os não-boletos); e, a cada import em
lote, sinalizar quando o arquivo diverge do ciclo configurado.

## Não-objetivos (YAGNI)

- Validar o dia de **fechamento** pelo arquivo (o PDF raramente traz a data de
  fechamento). Só o `due_day` é validado por import (o Vencimento é explícito).
- Prever vencimento de faturas futuras / gerar faturas.
- Ciclo para contas não-cartão.

## Modelo de dados

Dois campos novos em `accounts` (usados só quando `is_credit_card`):

- `closing_day` :integer (1–31), nullable — dia de fechamento.
- `due_day` :integer (1–31), nullable — dia de vencimento.

Ambos entram no `Account.changeset/2` cast, com `validate_inclusion 1..31`.

## Estimativa (dos boletos)

`CreditCards.estimate_cycle(account) :: %{closing_day, due_day}` a partir das
faturas-boleto (com `due_date`) da conta:

- `due_day` = dia mais comum (moda) entre os `due_date` dos boletos.
- `closing_day` = estimado como `due_day − @offset` (offset típico ~7 dias),
  normalizado a 1..31; se não houver boletos, retorna nils.

É uma estimativa **best-effort**; o usuário confirma/ajusta na tela de contas.
Não sobrescreve valores já preenchidos sem ação explícita.

## Competência a partir do ciclo (o coração)

`CreditCards.competencia_for(account, meta, transactions)` substitui o uso atual
de `competencia_from/2` na criação da fatura, QUANDO a conta tem ciclo
configurado:

- **Com Vencimento no arquivo** (boleto): competência = `beginning_of_month(due_date)`
  (inalterado).
- **Sem Vencimento**, com ciclo configurado: calcula o vencimento pelo ciclo a
  partir da data da transação mais recente `D`:
  1. Fechamento da fatura = primeiro `closing_day` **estritamente após** `D`
     (rola pro mês seguinte se `D` já passou do `closing_day` do mês de `D`).
  2. Vencimento = `due_day` no mês do fechamento se `due_day > closing_day`,
     senão no mês seguinte ao fechamento.
  3. competência = `beginning_of_month(vencimento)`.
- **Sem Vencimento e sem ciclo** (fallback): mantém `competencia_from/2` (mês da
  transação mais recente) — comportamento atual, sem regressão.
- **Sem transações e sem Vencimento**: nil (como hoje).

Exemplo (Amazon `2026-02`, `closing_day` 3, `due_day` 10, última transação
27/01): fecha 03/02 (primeiro dia-3 após 27/01), vence 10/02 (10 > 3, mesmo mês)
→ competência **Fev/26**.

### Recálculo do histórico

Mix task `cash_lens.recompute_competencia`: para cada conta de cartão com ciclo,
recalcula a competência das faturas existentes via `competencia_for/3`
(re-derivando das transações da fatura + o Vencimento persistido). Idempotente.
Boletos (com `due_date`) não mudam. Depois de recalcular, rodar a reconciliação
de pendentes de novo é recomendado (a competência corrigida pode mudar
elegibilidade de absorção).

## Validação pós-import

`DirectoryImporter.run/2` passa a coletar **divergências de ciclo** por conta:
para cada boleto importado cujo `due_date`-dia difere do `account.due_day`
configurado, adiciona uma divergência `%{account, arquivo, dia_arquivo,
dia_configurado}`.

- Exposta num novo campo `cycle_warnings` no `%Result{}` (ao lado de
  `warnings`/`errors`), para não misturar com avisos genéricos.
- `mix cash_lens.import` imprime as divergências.
- A tela de import em lote (`batch_import_modal_component`) mostra o resumo com
  um botão "Atualizar" que grava o `due_day` do arquivo na conta e re-estima o
  `closing_day`.

Só `due_day` é validado (o fechamento não vem no arquivo).

## UI

### Formulário de conta

Na tela de contas (`AccountLive.Form`), quando `is_credit_card`:

- Dois inputs: **Dia de fechamento** e **Dia de vencimento** (number, 1–31).
- Botão **"Estimar do histórico"** → chama `estimate_cycle/1` e preenche os
  campos (sem salvar; o usuário revisa e salva).

### Resumo de divergências (import em lote)

No componente de import em lote, após o import, se `result.cycle_warnings != []`,
lista cada divergência com um botão que atualiza a conta.

## Testes

- **Schema/changeset:** aceita `closing_day`/`due_day`; valida 1..31.
- **estimate_cycle/1:** moda do vencimento; closing = due − offset; nils sem
  boletos.
- **competencia_for/3:** boleto usa due month; não-boleto com ciclo calcula o
  vencimento correto (casos: transação antes/depois do closing_day, due_day
  maior/menor que closing_day, virada de ano); sem ciclo cai no fallback; sem
  transações → nil. O caso real (27/01, closing 3, due 10 → Fev) coberto.
- **Import:** cria fatura usando `competencia_for/3` quando a conta tem ciclo.
- **recompute_competencia:** atualiza competência das faturas existentes;
  idempotente; boletos inalterados.
- **Divergência:** `DirectoryImporter.run` popula `cycle_warnings` quando o
  Vencimento do arquivo difere do `due_day`; vazio quando bate ou sem ciclo.
- **LiveView:** form mostra os campos + botão estimar para cartão; resumo de
  divergências renderiza + o botão atualiza a conta.

## Arquivos

- Migration: `closing_day`, `due_day` em `accounts`.
- `lib/cash_lens/accounts/account.ex` — campos + cast + validação.
- `lib/cash_lens/credit_cards.ex` — `estimate_cycle/1`, `competencia_for/3`
  (usa/mantém `competencia_from/2` como fallback).
- `lib/cash_lens/parsers/ingestor.ex` — usar `competencia_for/3` no
  `maybe_create_statement`.
- `lib/cash_lens/parsers/directory_importer.ex` — coletar `cycle_warnings` no
  `Result`.
- `lib/mix/tasks/cash_lens.recompute_competencia.ex` — recálculo do histórico.
- `lib/cash_lens_web/live/account_live/form*` — inputs + botão estimar.
- `lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex` —
  resumo de divergências + ação atualizar.
- Testes correspondentes.
