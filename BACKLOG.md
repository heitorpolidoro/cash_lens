# CashLens Project Backlog & Engineering Guidelines

Este arquivo consolida as diretrizes estratégicas, decisões arquiteturais e o backlog de tarefas do projeto CashLens.

## 🏛️ Diretrizes e Decisões Arquiteturais (Estratégico)

- **Stack de Dados**: O PostgreSQL é o banco de dados definitivo. Planos anteriores de migração para MongoDB foram descartados. O sistema deve permanecer fortemente relacional.
- **Modelo Contábil**: O modelo de 'saldos encadeados' é central, mas reconhecido como um risco de performance. Qualquer alteração no core de `Accounting` deve prever snapshots para evitar processamento linear exaustivo.
- **Escalabilidade**: O sistema atual é single-user. Projetar novas funcionalidades (como Auth e Multi-tenancy) com a possibilidade de expansão para SaaS em mente.
- **Evolução de Ingestão**: A transição de parsers baseados em Regex/Texto para modelos baseados em IA (LLM/Ollama) é a direção estratégica para lidar com a complexidade de extratos bancários.

---

## 🔴 Prioridade 1: Dívida Técnica Crítica e Integridade (Imediato)
*Foco: Prevenir bugs silenciosos, viabilizar o desenvolvimento ágil e garantir a corretude dos dados.*

1. **Refatoração de Interface (LiveView) - Bloqueio de Dev**
   - [x] **Decompor `TransactionLive.Index`**: Quebrar o arquivo (~83KB, >1.4k linhas) em `LiveComponents` (ex: `[x] ImportModalComponent`, `[x] QuickCategoryComponent`, `[x] TransferLinkComponent`).
   - [x] **Extrair Templates HEEx**: Mover o conteúdo de `render/1` para arquivos `.html.heex` dedicados.
   - [x] **Remover Lógica de Negócio da UI**: Mover parsing e cálculos contábeis dos templates/LiveViews para os contextos `Transactions` ou `Accounting`.

2. **Integridade de Dados (PostgreSQL)**
   - [x] **Restrições de Unicidade Faltantes**: Adicionar unique index em `balances(account_id, year, month)` e `categories(parent_id, name)`.
   - [x] **Upsert Consistente**: Usar `on_conflict` em `calculate_monthly_balance` para evitar race conditions, dependendo da restrição de unicidade.

3. **Blindagem de Core (QA)**
   - [ ] **Testes de Parsers**: Implementar testes unitários reais para `csv_parser_test.exs` e `pdf_parser_test.exs`.
   - [ ] **Testes de Lógica de Negócio Vital**: Validar `TransferMatcher` (virtual twins) e o encadeamento de saldos de ponta a ponta (`Accounting`).

---

## 🟡 Prioridade 2: Core Business e Escalabilidade (Curto Prazo)
*Foco: Aumentar o valor do produto para o usuário e otimizar o sistema para suportar volume de dados.*

1. **Ingestão de Dados e Padronização**
   - [ ] **Implementar Parser OFX**: Adicionar suporte ao formato padrão bancário para facilitar a adoção.
   - [ ] **Padronização de Contratos**: Definir `behaviours` para os Parsers garantirem uma interface única (`parse/1`).
   - [ ] **Tratamento de Erros de Ingestão**: Substituir crashes (`Date.new!`) por erros graciosos e implementar estado de "Quarentena" para transações falhas.

2. **Performance de Banco de Dados**
   - [ ] **Snapshots de Balanço**: Implementar sistema de snapshot periódico para evitar o recálculo custoso de todo o histórico contábil.
   - [ ] **Otimização de Agregações**: Mover cálculos pesados de resumo mensal/histórico de Elixir para o SQL puro (`GROUP BY`, `SUM`).
   - [ ] **Árvore de Categorias**: Usar **CTE Recursiva (WITH RECURSIVE)** para buscar e gerenciar categorias filhas.
   - [ ] **Novos Índices**: Otimizar ordenação com índices em `transactions(date DESC, time DESC, inserted_at DESC)` e ativar extensão `pg_trgm` para buscas textuais via `ILIKE`.

---

## 🔵 Prioridade 3: Inteligência e Processamento (Médio Prazo)
*Foco: Automação avançada, Inteligência Artificial e processamento em background.*

1. **Inteligência Artificial (ML/AI)**
   - [ ] **Categorização via LLM**: Integrar com Ollama para classificar automaticamente transações obscuras, reduzindo o trabalho manual do usuário e do parser léxico.
   - [ ] **OCR para Comprovantes**: Integrar leitura de PDFs baseada em imagens ou cupons fiscais.

2. **Arquitetura Assíncrona e Infraestrutura**
   - [ ] **Workers / Processamento Assíncrono**: Introduzir `Oban` ou `Task.Supervisor` para rodar os parsers de importação e o recálculo de saldos em background, sem travar a UI.
   - [ ] **Qualidade de Código**: Configurar checagem de tipos estáticos (`dialyzer`) e linter (`credo`).
   - [ ] **Padronização de Logs**: Trocar `IO.puts` por chamadas ao módulo `Logger` contendo metadados (ex: account_id).
   - [ ] **Observabilidade**: Ativar `pg_stat_statements` em prod e incluir rastreios de telemetria no cálculo de balanços.

---

## 🟢 Prioridade 4: Features de Produto e Interface (Longo Prazo)
*Foco: Novas funcionalidades focadas no usuário final.*

1. **Novas Funcionalidades UX**
   - [ ] **Dashboard Principal**: Implementar gráficos de evolução de saldo e distribuição por categoria.
   - [ ] **Gestão de Assinaturas e Recorrências**: Painel para acompanhar serviços contínuos (Netflix, academia, etc).
   - [ ] **Metas Financeiras**: Progresso visual para controle de orçamentos e reservas.

2. **Visão de Produto Escalável**
   - [ ] **Segurança e Isolamento**: Implementar Autenticação (Login) e sistema Multi-tenant caso decida-se abrir o sistema para terceiros (SaaS).
   - [ ] **Exportação de Dados**: Geração de relatórios mensais estáticos em Excel ou PDF.
