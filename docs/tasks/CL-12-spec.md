# CL-12 — Redesenhar Central de Reembolsos (/reimbursements) com abas de ciclo de vida e conciliação mágica

## Scope
Reformulação completa da Central de Reembolsos (`/reimbursements`), estruturando a interface em torno do ciclo de vida cronológico das despesas corporativas ou médicas reembolsáveis. A interface elimina tabelas longas e empilhadas, organizando o fluxo em abas claras ("A Receber" e "Histórico Vinculado"). O cabeçalho conta com 3 cards de métricas organizados no fluxo exato do ciclo de vida, um bloco inteligente para confirmação em 1 clique de pares sugeridos automaticamente, um modal intuitivo de vinculação manual com cálculo de match em tempo real e um modal para marcar despesas do extrato como reembolsáveis por texto ou valor sem sair da tela.

Inclui:
- Divisão por Abas de Ciclo de Vida:
  - Aba "A Receber (Pendentes & Solicitados)": lista despesas que ainda aguardam ressarcimento.
  - Aba "Histórico Vinculado": lista pares já conciliados (despesa original e respectivo depósito de reembolso).
- 3 Cards de Ciclo de Vida no Topo (Ordem Cronológica Estrita):
  1. **A Solicitar**: transações marcadas como reembolso que ainda não foram submetidas ao plano/empresa (Ação Necessária).
  2. **Solicitado**: despesas com pedidos já formalizados aguardando compensação/depósito (Em Análise).
  3. **Recebidos (Últimos 12 meses)**: total de reembolsos compensados e vinculados nos últimos 12 meses.
- Card de Destaque para Conciliação Automática ("Pares Sugeridos"):
  - Destaca sugestões de pares detectados automaticamente pelo sistema (valores idênticos ou compatíveis com descrição correspondente).
  - Botão de confirmação em 1 clique (individual ou "Confirmar Todos") que estabelece o vínculo contábil imediatamente.
- Modal de Seleção do Extrato ("Marcar Despesa do Extrato"):
  - Botão no cabeçalho ("Marcar Despesa do Extrato") que abre modal de busca rápida sobre o histórico recente de despesas.
  - Campo de busca unificado que pesquisa dinamicamente por descrição (médico, clínica, exame, transporte) **e por valor numérico** (ex: `350`, `84,20`).
  - Lista apenas despesas que ainda não foram marcadas como reembolsáveis (`reimbursement_status == nil`).
  - Ao clicar em "+ Adicionar", atualiza a transação com `reimbursement_status: "pending"`, inserindo-a imediatamente no Card "1. A Solicitar" e na tabela "A Receber".
  - *Nota de integração*: A marcação e desmarcação de transações como reembolsáveis continua plenamente acessível na tela de Transações (`/transactions`) e em seu formulário de edição, funcionando em perfeita sincronia com esta central.
- Gestão do Ciclo da Despesa:
  - Badges visuais no extrato da aba para alternar status entre "Pendente" e "Solicitado", com campo rápido para salvar protocolo ou convênio.
- Barra Flutuante de Seleção em Lote e Modal de Vinculação Manual:
  - Permite selecionar uma despesa e abrir o modal de conciliação manual.
  - O modal lista depósitos de crédito candidatos, calculando em tempo real se o valor é "Match Perfeito (100%)", parcial ou com diferença a justificar.
- Atualização e adição de testes em `test/cash_lens_web/live/reimbursement_live_test.exs`.

Explicitamente fora de escopo (Out of Scope):
- Alteração no algoritmo de geração de chave de vínculo `reimbursement_link_key` no backend.
- Alteração na tabela `rejected_reimbursement_pairs`.

## Approach
### 1. Behavior
- A tela `/reimbursements` continua servida por `CashLensWeb.ReimbursementLive.Index`.
- O estado da aba ativa (`:pending` vs `:linked`) é controlado via `live_patch` com query param (`?tab=pending` ou `?tab=linked`).
- Os 3 cards são calculados no contexto `Transactions`:
  - `to_request`: soma de despesas reembolsáveis com `reimbursement_status == "pending"`.
  - `requested`: soma de despesas com `reimbursement_status == "requested"`.
  - `received_12m`: soma de transações de reembolso vinculadas nos últimos 12 meses.
- A confirmação de pares sugeridos chama `Transactions.link_reimbursement_pair/2` e atualiza a interface via streams/assigns reativos.
- O modal de marcação do extrato busca transações não-reembolsáveis recentes via `Transactions.list_transactions/1` aplicando filtro simultâneo de texto e valor, e o clique em adicionar chama `Transactions.update_transaction(t, %{reimbursement_status: "pending"})`.
- O modal de vínculo manual pesquisa transações de crédito elegíveis e exibe indicador visual de coerência de valor antes da confirmação.

### 2. Files Touched
- `lib/cash_lens_web/live/reimbursement_live/index.ex`: reestrutura render HEEx (3 cards de ciclo de vida, abas, card de pares sugeridos, modal de marcar despesa do extrato com busca por descrição/valor, tabela de ciclo de vida e modal de vínculo manual).
- `lib/cash_lens/transactions.ex`: adiciona helper para cálculo das 3 métricas de ciclo de vida de reembolso do cabeçalho e suporte a busca de candidatos por texto e valor.
- `test/cash_lens_web/live/reimbursement_live_test.exs`: testes para alternância de abas, cálculo dos 3 KPIs na ordem correta, modal de marcar despesa do extrato (com busca por valor e texto), confirmação de par sugerido e vínculo manual.

### 3. Test Criteria
- `test/cash_lens_web/live/reimbursement_live_test.exs` valida:
  - Cálculo e renderização dos 3 cards de métricas na ordem exata: A Solicitar, Solicitado, Recebidos.
  - Navegação entre as abas "A Receber" e "Histórico Vinculado".
  - Abertura do modal "Marcar Despesa do Extrato" com filtragem por descrição e por valor, convertendo transação para `reimbursement_status: "pending"`.
  - Ação de 1 clique para aprovar par sugerido.
  - Fluxo de vínculo manual com depósito compatível.
- `mix test test/cash_lens_web/live/reimbursement_live_test.exs` passa com 100%.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Separação por abas: A Receber (Pendentes e Solicitados) e Histórico Vinculado, eliminando a rolagem infinita de tabelas empilhadas
- [ ] 3 Cards de ciclo de vida no topo na ordem: A Solicitar (Ação Necessária), Solicitado (Em Análise) e Recebidos (Últimos 12 meses)
- [ ] Card de destaque para Pares Sugeridos com conciliação automática em 1 clique (Confirmar Todos ou individual)
- [ ] Modal de Marcar Despesa do Extrato permite buscar transações recentes por descrição e por valor numérico, adicionando-as ao fluxo de reembolso com 1 clique
- [ ] Badges claros para ciclo de reembolso (Pendente vs Solicitado) com alternância rápida e suporte a convênio/protocolo
- [ ] Barra de seleção em lote flutuante e modal de vínculo manual com detecção de Match Perfeito e cálculo de saldo parcial
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Integração externa com sistemas de convênio ou APIs de reembolso corporativo.
- Modificações em telas de conciliação bancária ou faturas de cartão.
