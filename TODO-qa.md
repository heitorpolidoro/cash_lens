# CashLens - Quality Assurance & Testing Roadmap

Este documento analisa o estado atual dos testes no projeto CashLens e define prioridades para garantir a robustez e confiabilidade do sistema.

## 📊 Estado Atual (Março 2026)

Atualmente, o projeto possui uma suite de testes básica (11 arquivos `*_test.exs`), composta majoritariamente por código gerado automaticamente pelo Phoenix.

### Tipos de Testes Presentes:
- **Unitários/Integração de Esquema (DataCase):** Testam CRUD básico nos contextos `Accounts`, `Transactions`, `Categories` e `Accounting`.
- **LiveView (ConnCase):** Testam navegação básica e submissão de formulários para as entidades principais.
- **Controller:** Apenas testes de erro padrão (HTML/JSON) e página inicial.

### Cobertura de Código:
- **Alta:** Operações básicas de banco de dados (CRUD) e navegação UI simples.
- **Inexistente:** Lógica de negócio complexa, parsers de arquivos e automações.

---

## 🚩 Gaps Críticos Identificados

### 1. Parsers de Extratos (`CashLens.Parsers`)
- **Problema:** Nenhuma cobertura para `CSVParser` e `PDFParser`. O parsing de extratos bancários é frágil devido a variações nos formatos dos bancos (ex: Banco do Brasil).
- **Risco:** Falhas silenciosas na importação de dados, descrições mal formatadas ou valores incorretos.

### 2. Automações de Transações (`CashLens.Transactions`)
- **AutoCategorizer:** Nenhuma cobertura para a lógica de atribuição de categorias via palavras-chave ou regras especiais de reembolso.
- **TransferMatcher:** Nenhuma cobertura para a lógica vital de linkagem de transferências e criação de "virtual twins" (ex: BB MM Ouro).
- **BulkIgnorePattern:** Lógica de ignorar transações em massa não testada.

### 3. Lógica Contábil (`CashLens.Accounting`)
- **Problema:** Os testes atuais de `Accounting` apenas verificam se um `Balance` pode ser criado/editado.
- **Falta:** Testar o cálculo real de saldos mensais (`calculate_monthly_balance/3`), o encadeamento de saldos entre meses (`get_chained_initial_balance/5`) e a propagação de mudanças via `recalculate_all_balances/0`.

### 4. Robustez de Transações
- **Fingerprinting:** Nenhuma verificação de que transações duplicadas são corretamente ignoradas via `fingerprint`.
- **Reembolsos:** Lógica de mudança de status de reembolso não coberta.

---

## 🚀 Recomendações de Melhoria

### Prioridade 1: Estabilidade de Importação
- [ ] **Testes de Parsers:** Criar `test/cash_lens/parsers/csv_parser_test.exs` com amostras reais (e anonimizadas) de extratos do Banco do Brasil.
- [ ] **Testes de Ingestão:** Verificar o fluxo `Ingestor -> AutoCategorizer -> TransferMatcher` para garantir que uma transação importada termine no estado correto.

### Prioridade 2: Integridade de Dados
- [ ] **Testes de Cálculo de Saldo:** Criar cenários de múltiplos meses para validar se o saldo final de Janeiro torna-se o inicial de Fevereiro.
- [ ] **Testes de Concorrência/Idempotência:** Garantir que re-importar o mesmo arquivo não duplique transações nem quebre os saldos.

### Prioridade 3: Lógica de Negócio UI
- [ ] **Refatoração e Testes de TransactionLive:** Como o `TransactionLive.Index` é complexo, adicionar testes para filtros de busca, seleções em massa e gatilhos de auto-matching na interface.

### Prioridade 4: Ferramental Avançado
- [ ] **Property-Based Testing:** Utilizar `ExUnitProperties` (StreamData) para validar que, não importa a ordem das transações, o somatório final dos saldos mensais sempre converge para o esperado.
- [ ] **Configuração de CI:** Garantir que `mix test` rode obrigatoriamente antes de qualquer merge em branches principais.

---

## 🛠 Próximos Passos Sugeridos
1. Começar por `test/cash_lens/parsers/csv_parser_test.exs` para blindar a entrada de dados.
2. Implementar testes para o `TransferMatcher` para evitar inconsistências em transferências.
3. Adicionar testes de integração para o cálculo de `Balance` em `CashLens.Accounting`.
