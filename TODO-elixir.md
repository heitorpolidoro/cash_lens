# TODO Elixir/OTP & Phoenix Refactoring

Este documento detalha as melhorias recomendadas para o backend do CashLens, focando em manutenibilidade, performance e boas práticas de Elixir/OTP.

## 1. Arquitetura e Modularização 🏗️

- [ ] **Refatorar `TransactionLive.Index`**:
    - O arquivo possui > 1.4k linhas. Extrair funcionalidades para `LiveComponent`s:
        - `ImportModalComponent`: Lógica de upload e validação de extratos.
        - `FilterSidebarComponent`: Gerenciamento de filtros complexos.
        - `QuickCategoryComponent`: Criação rápida de categorias.
        - `TransferLinkComponent`: Interface de vinculação de transferências.
    - Mover lógicas de negócio dos `handle_event` para o contexto `CashLens.Transactions`.

- [ ] **Padronizar Logs**:
    - Substituir todos os `IO.puts` por `Logger.info`, `Logger.debug` ou `Logger.error`.
    - Adicionar metadados aos logs (ex: `account_id`, `filename`).

- [ ] **Tipagem e Contratos**:
    - Adicionar `@spec` e `@type` em todos os módulos de contexto (`Accounting`, `Transactions`, `Categories`).
    - Definir `behaviours` para os Parsers para garantir que todos sigam a mesma interface (`parse/1`).

## 2. Performance e Banco de Dados ⚡

- [ ] **Otimizar Agregações**:
    - Migrar `get_historical_summary` e `get_historical_category_summary` para queries SQL puras (Ecto) usando `group_by` no banco de dados.
    - Evitar carregar milhares de structs `Transaction` na memória para calcular totais.

- [ ] **Processamento em Lote (Batching)**:
    - No `reapply_auto_categorization`, usar `Repo.transaction` com `insert_all` ou `update_all` para evitar múltiplas viagens ao banco.
    - Otimizar `recalculate_all_balances` para atualizar apenas os meses afetados a partir de uma alteração, em vez de recalcular tudo sempre.

- [ ] **Índices e Queries**:
    - Verificar índices para `fingerprint` e `transfer_key` nas transações.
    - Otimizar `list_latest_balances` para não depender de fragmentos de cálculo no `WHERE`.

## 3. Robustez e Tratamento de Erros 🛡️

- [ ] **Parsers Defensivos**:
    - Substituir `Date.new!` por `Date.new` e tratar o erro graciosamente nos parsers.
    - Implementar um sistema de "Quarentena" para linhas de extrato que falharem no parse, em vez de apenas ignorá-las ou usar `Date.utc_today()`.

- [ ] **Resultados Padronizados**:
    - Garantir que todas as funções de criação/atualização retornem `{:ok, struct}` ou `{:error, changeset}`. Evitar retornos como `{:ok, :duplicate}` que podem confundir o caller.

## 4. OTP e Processamento Assíncrono 🤖

- [ ] **Introduzir Workers (GenServer/Task)**:
    - Usar `Task.Supervisor` para processar imports de arquivos grandes em background, permitindo que a UI permaneça responsiva.
    - Criar um `GenServer` para gerenciar o cache de taxas de câmbio ou categorias frequentes se necessário.

- [ ] **PubSub Distribuído**:
    - Garantir que eventos de "Saldo Atualizado" sejam propagados corretamente para todos os componentes da tela sem recarregar a página inteira.

## 5. Qualidade de Código e Ferramentas 🛠️

- [ ] **Credo & Dialyzer**:
    - Adicionar `credo` para análise estática de estilo.
    - Configurar `dialyxir` para verificar consistência de tipos.

- [ ] **Testes Automatizados**:
    - Aumentar a cobertura de testes para os `Parsers` (casos de borda: valores negativos, datas inválidas, descrições com caracteres especiais).
    - Criar testes de integração para o fluxo de `TransferMatcher`.
