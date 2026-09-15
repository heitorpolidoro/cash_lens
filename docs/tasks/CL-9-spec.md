# CL-9 — Redesenhar Extrato de Transações (/transactions)

## Scope
Redesenho do Extrato de Transações (`/transactions`), transformando-o em uma central fluida, responsiva e contínua de consulta e categorização de movimentações financeiras. A interface abandona a paginação rígida com mês travado por padrão, adotando ordenação estritamente cronológica decrescente (mais recente primeiro), suporte a carregamento contínuo (scroll infinito via LiveView Streams), barra dinâmica de saúde/resumo financeiro e edição rápida de categorias inline com sugestões em 1 clique.

Inclui:
- Ordenação padrão por data e hora decrescente (`inserted_at` / `date` DESC).
- Remoção do bloqueio de mês corrente obrigatório por padrão: inicializa exibindo fluxo contínuo de transações recentes com suporte a paginação contínua (hook `InfiniteScroll` via Phoenix LiveView streams).
- Barra dinâmica de status:
  - Estado Padrão (Sem filtros ativos): exibe a "Barra de Saúde do Extrato" com contadores clicáveis de atenção:
    - Transações Sem Categoria (clique filtra instantaneamente o extrato para `category_id=nil`).
    - Reembolsos a Receber (clique direciona para `/reimbursements`).
    - Transferências Pendentes/Identificadas (clique direciona para `/transfers`).
  - Estado Filtrado (Qualquer filtro, busca ou seleção ativa): transiciona suavemente para o "Resumo Financeiro do Filtro", apresentando Entradas (+), Saídas (-) e Balanço Líquido totalizado do recorte pesquisado.
- Edição rápida de categoria na própria linha da tabela:
  - Seletor rápido ou popover de categoria sem necessidade de abrir formulário de página inteira.
  - Exibição de badge clicável de sugestão inteligente (`✨ Sugestão: Alimentação`) que aprova e persiste a categoria sugerida com 1 único clique.
- Exibição limpa de badges de reembolso:
  - Destaca despesas com reembolso pendente, parcial ou liquidado, e vinculação bidirecional com a transação de crédito correspondente.
- Limpeza dos elementos legados de importação de dentro do extrato (redirecionando para `/imports`).
- Testes unitários e de integração em `test/cash_lens_web/live/transaction_live_test.exs`.

Explicitamente fora de escopo (Out of Scope):
- Modificação dos algoritmos de detecção de transferências ou categorização automática no backend `Transactions`.
- O formulário modal de cadastro/edição manual de transações (pertencente ao escopo da tarefa `CL-10`).

## Approach
### 1. Behavior
- A tela `/transactions` continua servida por `CashLensWeb.TransactionLive.Index`.
- As transações são gerenciadas via LiveView Streams (`stream(:transactions, ...)`), garantindo renderização eficiente e inserções dinâmicas sem re-renderizar a lista inteira.
- Quando o usuário atinge o final da visualização, o hook JS `InfiniteScroll` emite evento `load_more` para buscar a próxima página de transações.
- A alternância entre a Barra de Saúde e o Card de Resumo Financeiro é calculada com base na presença de filtros no assign `@filters` (termo de busca, conta, categoria, tipo, período).
- A aprovação de sugestão de categoria emite `apply_suggested_category` com `{id, category_id}`, atualizando a linha no stream.

### 2. Files Touched
- `lib/cash_lens_web/live/transaction_live/index.ex`: atualiza queries padrão de ordenação, streams, infinite scroll, alternância de card saúde/resumo e categorização rápida.
- `assets/js/app.js`: adiciona ou atualiza o hook `InfiniteScroll` com `IntersectionObserver`.
- `lib/cash_lens/transactions.ex`: garante função para cálculo rápido de métricas de saúde e totais de busca filtrada.
- `test/cash_lens_web/live/transaction_live_test.exs`: adiciona testes para ordenação decrescente, barra de saúde vs resumo financeiro, e aprovação de sugestões.

### 3. Test Criteria
- `test/cash_lens_web/live/transaction_live_test.exs` valida:
  - Ordenação correta das transações (mais recentes no topo).
  - Exibição da barra de saúde no estado padrão e transição para resumo financeiro quando filtrado.
  - Evento de carregamento de mais itens via stream.
  - Aplicação imediata de categoria sugerida com 1 clique.
- `mix test test/cash_lens_web/live/transaction_live_test.exs` passa com 100%.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Extrato ordenado rigorosamente da transação mais recente para a mais antiga por padrão
- [ ] Filtro de período sem mês travado por padrão (Todos os Períodos / fluxo contínuo) com suporte a scroll infinito via LiveView stream e IntersectionObserver
- [ ] Barra permanente de Saúde do Extrato exibindo contadores clicáveis: Sem Categoria (filtra no local), Reembolsos a Receber (link para /reimbursements) e Transferências (link para /transfers)
- [ ] Transição automática da Barra de Saúde para o Card Resumo Financeiro (Entradas, Saídas e Balanço Líquido do recorte) ao aplicar qualquer filtro ou busca
- [ ] Edição rápida de categoria diretamente na linha da tabela com badge de aprovação em 1 clique para sugestões (✨ Sugestão: X)
- [ ] Exibição limpa de badges de reembolso com vínculo bidirecional entre a despesa e o crédito de depósito
- [ ] Remoção de modais/botões legados de importação, concentrando-os na /imports
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Criação do modal unificado de formulário manual (escopo de CL-10).
- Alteração nos parsers de arquivos.
