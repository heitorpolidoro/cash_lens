# CL-6 — Reformular tela de Fechamento do Mês e Comparação (/months) com navegação de ano/mês, simetria e comparativo limpo

## Scope
Reformulação completa da tela de Fechamento do Mês (`/months/:year/:month`), aprimorando a navegação temporal, a clareza dos indicadores contábeis e a ferramenta de comparação entre períodos. A tela passa a oferecer seletores desacoplados de ano e mês, cards de KPI simétricos e uma visão comparativa estritamente cronológica focada na operação financeira (resultado líquido e variação por categoria).

Inclui:
- Controles de navegação rápida desacoplados no cabeçalho: seletor de Ano (`< [Ano] >`) e seletor de Mês (`< [Mês] >`), permitindo avançar e retroceder anos e meses de forma independente sem dropdowns confusos.
- Alternância de visualização entre "Visão Mensal" e "Comparar Períodos".
- Visão Mensal (Mês Único):
  - 4 KPI Cards: Saldo de Abertura (azul), Receitas Totais (verde), Despesas Totais (rosa) e Saldo Final Consolidado (azul com badge indicando Superávit ou Déficit operacional).
  - Tabelas de detalhamento de Receitas e Despesas por Categoria, incluindo valor absoluto, percentual do total (`%`) e barra visual de representatividade.
- Modo de Comparação entre Meses:
  - Ordenação cronológica estrita: Mês Base (mais antigo) à esquerda, Mês em Análise (mais recente) à direita, e coluna central/direita com a Variação (`+/- R$`). Bloqueio contra seleções temporais invertidas.
  - KPIs comparativos focados na operação: comparativo de Receitas, Despesas e Resultado Líquido Operacional (sem misturar saldos patrimoniais acumulados de contas).
  - Tabelas comparativas de Receitas e Despesas calculadas pela união ativa das categorias: exibe todas as categorias movimentadas em pelo menos um dos períodos (se zerou em um mês, exibe R$ 0,00 e o delta correspondente de economia ou aumento, ocultando apenas categorias com R$ 0,00 em ambos os meses).
- Atualização e adição de testes em `test/cash_lens_web/live/month_live_test.exs`.

Explicitamente fora de escopo (Out of Scope):
- Alteração no fechamento de faturas de cartão de crédito.
- Alteração na lógica de cálculo de saldos em `Accounting.Balance`.

## Approach
### 1. Behavior
- A rota `/months/:year/:month` continua apontando para `CashLensWeb.MonthLive.Show`.
- A navegação entre anos e meses altera a URL via `push_patch` mantendo o estado da LiveView ágil.
- O modo de comparação adiciona parâmetros de query (`?compare_year=...&compare_month=...`).
- O LiveView calcula a união das categorias movimentadas no período base e no período alvo, garantindo que o delta seja exibido de forma consistente.
- Todos os componentes visuais adotam o tema claro oficial com bordas `border-slate-200` e tipografia limpa, espelhando `docs/tasks/CL-6-mock.html`.

### 2. Files Touched
- `lib/cash_lens_web/live/month_live/show.ex`: atualiza montagem, parâmetros de rota, cálculo dos deltas comparativos e controle de modo (único vs comparativo).
- `lib/cash_lens_web/live/month_live/month_panel.ex`: adapta ou unifica a renderização dos blocos de KPI e tabelas de categorias.
- `test/cash_lens_web/live/month_live_test.exs`: valida a navegação independente de ano/mês, os 4 KPIs no modo único, e as regras da união de categorias no modo comparativo.

### 3. Test Criteria
- `test/cash_lens_web/live/month_live_test.exs` cobre:
  - Navegação de ano e mês via eventos LiveView.
  - Renderização correta dos 4 cards de KPI e percentuais por categoria no modo único.
  - Exibição de categorias com valor zerado em um dos meses no modo comparativo, com delta calculado.
- `mix test test/cash_lens_web/live/month_live_test.exs` passa sem falhas.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Seletores independentes de ano e mês (< [Ano] > / < [Mês] >) no cabeçalho para navegação rápida entre anos e meses
- [ ] Modo de mês único com cards de KPI (Saldo de Abertura em azul, Receitas em verde, Despesas em rosa, Saldo Final em azul com badge de superávit/déficit) e tabelas com % do total e barras de progresso
- [ ] Modo de comparação cronológico (Esquerda = Mês Base, Direita = Mês em Análise com coluna de Diferença +/- R$) com bloqueio de coerência temporal
- [ ] Foco na operação no comparativo: sem saldos inicial/final de contas, exibindo Resultado Líquido e totais com comparativo nos cabeçalhos alinhados sem badges
- [ ] Tabelas de Receitas e Gastos por Categoria no comparativo exibindo a união ativa de categorias (nunca 0 com 0; se zerou em um mês, exibe R$ 0,00 e o delta de economia/gasto)
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Alterações em schemas ou migrações de banco de dados.
- Modificações em outras LiveViews.
