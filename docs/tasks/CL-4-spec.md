# CL-4 — Reformular Dashboard (/) com foco no mês atual e layout simplificado

## Scope
Reformulação do Dashboard principal (`/`) do CashLens para focar exclusivamente no mês atual e no histórico real consolidado dos últimos 12 meses. O objetivo é remover elementos visuais poluídos, projeções futuras baseadas em médias, acumulados de 3/6/12 meses e gráficos de categorias (rosca), mantendo o tema claro oficial e alinhando a tela à identidade visual moderna do sistema.

Inclui:
- Simplificação do `PageController`: remoção do cálculo de projeções futuras (`generate_projections`), médias (`calculate_averages`), acumulados de balanço (`trailing_balance_sum`) e extração de dados de categorias fixas/variáveis (`extract_category_data`).
- Atualização do template `home.html.heex` para apresentar:
  - 4 KPI cards de topo: Saldo Atual (soma das contas ativas), Receitas do mês corrente, Despesas do mês corrente e Balanço do mês corrente.
  - Layout em grid de 2 colunas principais (2/3 e 1/3 no desktop):
    - Coluna esquerda (2/3): Gráfico de Evolução Financeira Consolidada com as 4 séries originais (Saldo Final, Entradas, Saídas, Balanço Líquido em barras), terminando no mês corrente sem projeções futuras ou faixas pontilhadas de projeção.
    - Coluna direita (1/3): Card "Minhas Contas", listando contas ativas não encerradas com seus saldos atuais e total consolidado, sem badges de "Live" ou menções a integrações externas.
- Limpeza dos scripts em `assets/js/app.js`: remoção dos inicializadores `initCategoryChart` (`fixedChart` e `variableChart`) e remoção da lógica de projeção futura (linhas verticais tracejadas e destaques de projeção) no gráfico `balanceChart`.
- Atualização dos testes de controller (`test/cash_lens_web/controllers/page_controller_test.exs`) para refletir os novos assigns e a ausência dos elementos removidos.

Explicitamente fora de escopo (Out of Scope):
- Alterações em regras de negócio de cálculo de saldos no contexto `Accounting` ou `Transactions`.
- Funcionalidades de sincronização bancária Pluggy (permanecem inalteradas no backend, mas sem menção visual na interface do dashboard).
- Redesenho de outras telas (`/transactions`, `/balances`, `/months`).

## Approach
### 1. Behavior
- A rota `/` continua servida pelo `PageController.home/2`.
- Os assigns passados para o template serão estritamente os necessários: `@total_balance`, `@monthly_income`, `@monthly_expenses`, `@monthly_balance`, `@summary_month`, `@chart_data`, e `@accounts`.
- `@chart_data` conterá apenas os meses históricos reais (últimos 12 meses até o mês corrente), serializados em JSON sem marcação `is_projection: true`.
- O template renderiza o visual claro limpo, com bordas `border-slate-200` e fundos `bg-white`, consistente com `docs/tasks/CL-4-mock.html`.
- O card "Minhas Contas" exibe apenas contas abertas que não são cartão de crédito, com avatar/cor, nome, banco e saldo formatado, além de um rodapé com "Total em Contas".

### 2. Files Touched
- `lib/cash_lens_web/controllers/page_controller.ex`: remove cálculos de projeção (`generate_projections`, `calculate_averages`, `installment_impact_for`, etc.), trailing sums e extração de categorias; ajusta assigns do render.
- `lib/cash_lens_web/controllers/page_html/home.html.heex`: reestrutura o markup eliminando tabelas de 12 meses e gráficos de categorias; organiza KPI cards e layout side-by-side de Evolução Financeira + Minhas Contas.
- `assets/js/app.js`: remove código JS dos gráficos `fixedChart`/`variableChart` e simplifica o `balanceChart` retirando o plugin de linha vertical de projeção.
- `test/cash_lens_web/controllers/page_controller_test.exs`: atualiza asserções de assigns e HTML renderizado.

### 3. Test Criteria
- `test/cash_lens_web/controllers/page_controller_test.exs` verifica que `GET /` responde `200 OK`, inclui os cards principais, o gráfico de evolução financeira e o card Minhas Contas, e não contém as tabelas de 12 meses ou gráficos de categorias removidos.
- `mix test` e `mix quality_check` passam com 0 erros e 0 avisos.

## Expected Results
- [ ] PageController remove cálculos de projeção futura, acumulados de 3/6/12 meses e extração de categorias de rosca
- [ ] Dashboard exibe 4 cards de topo (Saldo Atual, Receitas, Despesas, Balanço), gráfico de Evolução Financeira Consolidada e card Minhas Contas ao lado
- [ ] Gráfico de Evolução Financeira Consolidada mantém o visual original de 4 métricas terminando no mês corrente sem projeções futuras
- [ ] Tabela de histórico mensal de 12 meses e gráficos de Gastos Fixos e Variáveis são removidos do dashboard
- [ ] Card Minhas Contas é posicionado ao lado do gráfico exibindo saldos atuais e total consolidado sem tags de Pluggy
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Qualquer alteração nos módulos de backend `Accounting`, `Transactions` ou `Installments`.
- Alteração nos fluxos de importação ou telas LiveView.
