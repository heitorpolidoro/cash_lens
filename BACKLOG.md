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
   - [x] **Decompor `TransactionLive.Index`**: Quebrar o arquivo em `LiveComponents`.
   - [x] **Extrair Templates HEEx**: Mover o conteúdo de `render/1` para arquivos `.html.heex` dedicados.
   - [x] **Remover Lógica de Negócio da UI**: Mover parsing e cálculos contábeis para os contextos `Transactions` ou `Accounting`.

2. **Integridade de Dados (PostgreSQL)**
   - [x] **Restrições de Unicidade Faltantes**: Adicionar unique index em `balances(account_id, year, month)`.
   - [x] **Upsert Consistente**: Usar `on_conflict` em `calculate_monthly_balance` para evitar race conditions.

3. **Blindagem de Core (QA)**
   - [x] **Testes de Parsers**: Implementar testes unitários reais para `csv_parser_test.exs` e `pdf_parser_test.exs`.
   - [x] **Testes de Lógica de Negócio Vital**: Validar `TransferMatcher` (virtual twins) e o encadeamento de saldos de ponta a ponta (`Accounting`).

---

## 🟡 Prioridade 2: Core Business e Escalabilidade (Curto Prazo)
*Foco: Aumentar o valor do produto para o usuário e otimizar o sistema para suportar volume de dados.*

1. **Ingestão de Dados e Padronização**
   - [x] **Implementar Parser OFX**: Adicionado suporte ao formato padrão bancário via `OFXParser`.
   - [x] **Padronização de Contratos**: Definido behaviour `CashLens.Parsers.Parser` e aplicado aos parsers.
   - [ ] **Tratamento de Erros de Ingestão**: Substituir crashes (`Date.new!`) por erros graciosos e implementar estado de "Quarentena".

2. **Performance de Banco de Dados**
   - [ ] **Snapshots de Balanço**: Implementar sistema de snapshot periódico para evitar o recálculo custoso.
   - [x] **Árvore de Categorias**: Usar **CTE Recursiva (WITH RECURSIVE)** para buscar e gerenciar categorias filhas.
   - [x] **Otimização de Agregações**: Movido cálculos de resumo mensal/histórico para SQL puro (`SUM`, `GROUP BY`).
   - [ ] **Novos Índices**: Otimizar ordenação com índices em `transactions(date DESC, time DESC, inserted_at DESC)`.

---

## 🔵 Prioridade 3: Inteligência e Processamento (Médio Prazo)
*Foco: Automação avançada, Inteligência Artificial e processamento em background.*

1. **Inteligência Artificial (ML/AI)**
   - [ ] **Categorização via LLM**: Integrar com Ollama para classificar automaticamente transações obscuras.
   - [ ] **OCR para Comprovantes**: Integrar leitura de PDFs baseada em imagens.

2. **Arquitetura Assíncrona e Infraestrutura**
   - [ ] **Workers / Processamento Assíncrono**: Introduzir `Oban` ou `Task.Supervisor` para rodar parsers em background.
   - [ ] **Qualidade de Código**: Configurar checagem de tipos estáticos (`dialyzer`) e linter (`credo`).
   - [x] **Padronização de Logs**: Trocado `IO.puts` por chamadas ao módulo `Logger` no Ingestor.
   - [ ] **Observabilidade**: Ativar `pg_stat_statements` em prod e incluir rastreios de telemetria.

---

## 🟢 Prioridade 4: Features de Produto e Interface (Longo Prazo)
*Foco: Novas funcionalidades focadas no usuário final.*

1. **Novas Funcionalidades UX**
   - [ ] **Dashboard Principal**: Implementar gráficos de evolução de saldo e distribuição por categoria.
   - [ ] **Gestão de Assinaturas e Recorrências**: Painel para acompanhar serviços contínuos.
   - [ ] **Metas Financeiras**: Progresso visual para controle de orçamentos e reservas.

2. **Visão de Produto Escalável**
   - [ ] **Segurança e Isolamento**: Implementar Autenticação (Login) e sistema Multi-tenant.
   - [ ] **Exportação de Dados**: Geração de relatórios mensais estáticos em Excel ou PDF.
