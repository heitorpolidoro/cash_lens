# SQL Refactoring & Best Practices (TODO)

Este documento contém sugestões de melhorias para o banco de dados PostgreSQL e padrões de consulta Ecto do CashLens.

## 1. Integridade de Dados e Restrições

- [ ] **Restrição de Unicidade em Balanços**: Atualmente não há garantia no nível do banco de dados de que um `account_id` tenha apenas um registro por `year` e `month`.
  - *Sugestão*: Adicionar um índice único composto em `balances(account_id, year, month)`.
- [ ] **Nomes de Categorias Irmãs**: Categorias sob o mesmo pai não deveriam ter o mesmo nome.
  - *Sugestão*: Adicionar um índice único em `categories(parent_id, name)`.
- [ ] **Políticas de Deleção (Cascading)**: Muitos relacionamentos usam `on_delete: :nothing`.
  - [ ] Revisar `balances.account_id`: Deveria ser `:delete_all` ou `:restrict`?
  - [ ] Revisar `transactions.account_id`: Deveria ser `:delete_all` ou `:restrict`?
  - [ ] Revisar `categories.parent_id`: Deveria ser `:restrict` para evitar a deleção de categorias pai que possuem subcategorias.

## 2. Otimização de Índices e Performance

- [ ] **Índice em Transações para Ordenação**: A maioria das listagens ordena por data decrescente.
  - *Sugestão*: Criar um índice composto em `transactions(date DESC, time DESC, inserted_at DESC)`.
- [ ] **Índices Funcionais para Filtros de Data**: Consultas que usam `extract(year/month from date)` não aproveitam índices normais.
  - *Sugestão*: Adicionar índices funcionais ou considerar adicionar colunas redundantes (ex: `year`, `month`) se a performance de leitura for crítica.
- [ ] **Busca de Texto (Trigramas)**: A busca por descrição usa `ILIKE %search%`, o que é lento em tabelas grandes.
  - *Sugestão*: Ativar a extensão `pg_trgm` e criar um índice GIN na coluna `description`.
- [ ] **Chaves de Transferência e Reembolso**: Consultas filtram por `transfer_key` e `reimbursement_link_key`.
  - *Sugestão*: Adicionar índices nessas colunas UUID.
- [ ] **Índice em Valores (Amount)**: Útil para filtros de faixa de preço e auditoria.
  - *Sugestão*: Criar índice em `transactions(amount)`.

## 3. Refatoração de Padrões de Consulta (Ecto/PostgreSQL)

- [ ] **Cálculos em Banco de Dados**:
  - `CashLens.Transactions.get_monthly_summary` e `get_historical_summary` processam dados em Elixir após carregar os registros.
  - *Refatoração*: Mover os agrupamentos (`GROUP BY`) e somas para o PostgreSQL usando fragmentos ou queries SQL puras para melhor performance.
- [ ] **Recursividade de Categorias**: `get_category_ids_with_children` só busca o primeiro nível de filhos.
  - *Refatoração*: Implementar uma **CTE Recursiva (WITH RECURSIVE)** para buscar toda a árvore de categorias de forma robusta e eficiente.
- [ ] **Upsert Consistente**: Em `CashLens.Accounting.calculate_monthly_balance`, a lógica de "buscar ou criar" é passível de race conditions.
  - *Refatoração*: Usar `Repo.insert(..., on_conflict: :replace_all, conflict_target: [:account_id, :year, :month])` após adicionar a restrição de unicidade.

## 4. Monitoramento e Manutenção

- [ ] **pg_stat_statements**: Ativar o monitoramento de queries lentas no ambiente de desenvolvimento/produção para identificar gargalos reais conforme o banco cresce.
- [ ] **Análise de Fingerprint**: O cálculo do `fingerprint` de transações é feito em Elixir. Embora funcione bem, mudanças na lógica de geração de fingerprint exigirão uma migração para regenerar hashes antigos e evitar duplicatas não detectadas.
