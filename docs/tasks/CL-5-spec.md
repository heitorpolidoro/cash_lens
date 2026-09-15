# CL-5 — Reformular tela de Saldos (/balances) com fechamento contábil, linha de total e ajuste de saldo

## Scope
Reformulação completa da tela de Histórico de Saldos (`/balances`), transformando-a em uma ferramenta de fechamento contábil limpa e funcional. A tela separa os filtros da tabela, remove colunas desnecessárias, torna as linhas clicáveis para inspeção rápida de extrato, introduz um rodapé (`tfoot`) com o total consolidado das contas e disponibiliza um modal de ajuste rápido de saldo final com opções de rendimento ou correção histórica.

Inclui:
- Reposicionamento dos filtros de Ano, Mês e Conta para uma barra dedicada externa ao topo da tabela, com botão para limpar filtros.
- Remoção do botão de cabeçalho "Recalcular Tudo" (operação sensível reservada a rotinas administrativas).
- Reestruturação da tabela de saldos:
  - Remoção da coluna de texto "Ver Extrato" e da coluna "Somente leitura".
  - Transformação das linhas (`<tr>`) em links/ações clicáveis que redirecionam para o extrato filtrado (`/transactions?account_id=...&year=...&month=...`).
  - Adição de botão de lápis discreto ao lado do Saldo Final com `phx-click="open_adjust"` para abrir o modal de ajuste sem disparar a navegação da linha.
  - Inclusão de rodapé consolidado (`<tfoot>`) que soma os valores visíveis (Saldo Inicial, Receitas, Despesas, Transferências de Entrada/Saída e Saldo Final Total).
- Modal LiveView de Ajuste de Saldo Final:
  - Exibe o saldo calculado atual, o campo para digitar o saldo real do extrato e a diferença calculada em tempo real.
  - Opção 1 (Rendimento do Mês): cria uma transação de receita na categoria de Rendimentos no último dia do mês correspondente.
  - Opção 2 (Correção de Saldo Inicial): ajusta o saldo de abertura da conta e dispara a cadeia de recálculo histórico de saldos.
- Atualização e adição de testes em `test/cash_lens_web/live/balance_live_test.exs`.

Explicitamente fora de escopo (Out of Scope):
- Alterações no modelo subjacente de encadeamento de saldos (`CashLens.Accounting.Balance`).
- Modificações na tela de Fechamento do Mês (`/months`) ou Extrato de Transações (`/transactions`).

## Approach
### 1. Behavior
- A rota `/balances` permanece gerenciada por `CashLensWeb.BalanceLive.Index`.
- Ao selecionar filtros, o LiveView recalcula a lista de saldos exibidos e computa os totais consolidados no assign `@totals` para preencher o `<tfoot>`.
- O clique na linha navega via `push_navigate` para `/transactions?account_id=:account_id&month=:month&year=:year`.
- O clique no lápis de ajuste emite evento `open_adjust_modal` com `{account_id, year, month}` populando os assigns do modal e exibindo-o.
- O envio do formulário de ajuste executa a ação selecionada via contexto `Accounting` e recarrega a tabela de saldos com flash de sucesso.

### 2. Files Touched
- `lib/cash_lens_web/live/balance_live/index.ex`: reestrutura render HEEx (barra de filtros, tabela com tfoot, modal de ajuste) e handlers de eventos (`filter`, `open_adjust`, `apply_adjust`, `close_modal`).
- `lib/cash_lens/accounting.ex`: adiciona helper para aplicação de ajuste de saldo (criação de transação de rendimento ou reajuste de saldo inicial).
- `test/cash_lens_web/live/balance_live_test.exs`: testa os filtros, renderização do tfoot consolidado, navegação ao extrato e modal de ajuste.

### 3. Test Criteria
- `test/cash_lens_web/live/balance_live_test.exs` verifica renderização dos filtros externos, cálculo e exibição do `<tfoot>` consolidado, abertura do modal de ajuste e ausência de colunas legadas e botão "Recalcular Tudo".
- `mix test test/cash_lens_web/live/balance_live_test.exs` passa com 100% de sucesso.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Filtros de Ano, Mês e Conta posicionados fora da tabela em barra própria
- [ ] Linha de total consolidado no rodapé (tfoot) somando saldo inicial, receitas, despesas, transferências e saldo final total
- [ ] Linhas da tabela com clique direto para abrir o extrato da respectiva conta no mês correspondente
- [ ] Modal de ajuste de saldo acionado por lápis com opções de Rendimento do Mês e Correção de Saldo Inicial Histórico
- [ ] Remoção da coluna Somente leitura e da coluna de texto Ver Extrato
- [ ] Remoção do botão Recalcular Tudo do cabeçalho de saldos
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Alterações no algoritmo de fingerprint de transações.
- Modificações em outras LiveViews além de BalanceLive.
