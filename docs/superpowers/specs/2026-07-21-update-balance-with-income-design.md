# Atualizar saldo com rendimentos

**Data:** 2026-07-21
**Status:** Aprovado (brainstorming)

## Problema

Contas de investimento (poupança, "Rende Fácil" etc.) rendem juros que não
aparecem como transações importadas — o saldo real da conta diverge aos
poucos do saldo calculado pelo sistema (`Accounting.list_latest_balances/0`),
e não há como registrar essa diferença sem editar manualmente a categoria de
cada transação ou mexer no saldo inicial da conta.

## Mecanismo existente (para contraste)

O formulário de edição de conta (`AccountLive.Form`, `save_account/3` para
`:edit`) já tem um campo "saldo atual editável": ao mudar esse valor, o
sistema calcula a diferença e soma no `balance` (saldo inicial/base) da
conta, silenciosamente. Nenhuma transação é criada — o ajuste fica invisível
no extrato e nos relatórios de receita/despesa.

A feature abaixo é deliberadamente diferente: a diferença vira uma
**transação real**, categorizada como `Rendimento`, visível no extrato e nos
relatórios.

## Objetivo

Na tela `/accounts` (lista de contas), abaixo do valor da coluna "Saldo
Atual", adicionar um botão "Atualizar com Rendimentos" para contas que não
são cartão de crédito. Ao clicar, abre um modal pedindo o novo saldo; ao
confirmar, cria uma transação de categoria `Rendimento` com a diferença
entre o novo saldo informado e o saldo atual calculado.

## Não-objetivos (YAGNI)

- Editar a data da transação criada (sempre usa a data de hoje).
- Editar a descrição da transação criada (sempre "Rendimento").
- Disponibilizar o botão para contas de cartão de crédito.
- Alterar ou remover o mecanismo existente de "saldo atual editável" no
  formulário de edição de conta.

## Fluxo

1. Na linha de uma conta não-cartão, um botão pequeno aparece abaixo do
   valor de "Saldo Atual" na tabela de `/accounts`.
2. Clicar abre um modal mostrando o saldo atual calculado (somente leitura)
   e um campo numérico para o novo saldo.
3. Ao confirmar (`phx-submit`):
   - `diferença = novo_saldo - saldo_atual_calculado`.
   - Se `diferença == 0`: nenhuma transação é criada; o modal fecha com uma
     mensagem informativa ("Nenhuma diferença a registrar").
   - Se `diferença != 0` (positiva ou negativa, sem restrição de sinal):
     chama `CashLens.Transactions.create_transaction/1` com:
     - `account_id`: a conta da linha clicada
     - `date`: `Date.utc_today()`
     - `description`: `"Rendimento"`
     - `amount`: `diferença`
     - `category_id`: o id da categoria `Rendimento` (slug `rendimento`,
       já existente — `CashLens.Categories.get_category_by_slug("rendimento")`)
4. `create_transaction/1` já recalcula os saldos da conta como efeito
   colateral existente (`Accounting.rebuild_account_balances/1`). A
   LiveView recarrega `@current_balances` (mesma lógica do `mount/3`) e
   fecha o modal com uma mensagem de sucesso.

## Validação e erros

- Campo de novo saldo vazio ou não-numérico: erro inline no formulário do
  modal, não fecha o modal, não cria nada.
- Categoria `Rendimento` não encontrada no banco (não deveria acontecer,
  mas é uma dependência externa ao código): flash de erro, nada é criado.
- Botão "Atualizar com Rendimentos" não aparece para contas com
  `is_credit_card: true`.

## Arquivos

- `lib/cash_lens_web/live/account_live/index.ex` — botão na tabela, novo
  assign de estado do modal (`@update_balance_modal`), handlers
  `open_update_balance_modal` / `update_balance_with_income` /
  `close_update_balance_modal`, e o markup do modal.
- Testes correspondentes em `test/cash_lens_web/live/account_live/index_test.exs`
  (ou arquivo equivalente, criando se não existir): criação da transação com
  diferença positiva e negativa, caso de diferença zero (nenhuma transação
  criada), e visibilidade do botão restrita a contas não-cartão.

## Testes

- Diferença positiva: cria transação com `amount` positivo, categoria
  `Rendimento`, saldo atual da tela reflete o novo valor.
- Diferença negativa: cria transação com `amount` negativo.
- Diferença zero: nenhuma transação criada, mensagem informativa exibida.
- Botão não aparece para conta com `is_credit_card: true`.
- Campo de saldo inválido/vazio: erro de validação, modal permanece aberto.
