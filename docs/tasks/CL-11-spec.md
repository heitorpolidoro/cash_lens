# CL-11 — Redesenhar tela de Parcelamentos (/installments) com suporte a Financiamentos e Consórcios

## Scope
Evolução da tela de Parcelamentos (`/installments`) de um simples agrupador de compras de cartão de crédito para uma central consolidada de Compromissos a Prazo. A tela passa a suportar três modalidades distintas: Cartão de Crédito (compras parceladas de curto/médio prazo), Financiamentos (dívidas de longo prazo com amortização e juros) e Consórcios (parcelas com carta de crédito e status de contemplação). O cabeçalho ganha cards com métricas globais de comprometimento mensal, saldo devedor e alívio de fluxo de caixa nos próximos 90 dias, além de um gráfico de barras empilhadas e modal inteligente de cadastro.

Inclui:
- Extensão do domínio de compromissos em `CashLens.Installments`:
  - Campo `commitment_type` no schema de grupo: `"credit_card"` (padrão), `"financing"`, `"consorcio"`.
  - Campos opcionais para financiamentos: taxa de juros, prazo em meses, valor financiado total.
  - Campos opcionais para consórcios: valor da carta de crédito e flag/data de contemplação (`is_contemplated`).
- 3 Cards Globais de Destaque no Topo:
  - Comprometimento Mensal: total a pagar no mês corrente, com discriminação visual por tipo e quantidade de compromissos ativos entre parênteses: `Cartão (X compras)`, `Financiamentos (Y)`, `Consórcios (Z)`.
  - Saldo Devedor Consolidado: soma do saldo devedor restante em todas as dívidas ativas.
  - Alívio no Fluxo de Caixa (Próximos 90 dias): previsão da redução do valor mensal comprometido conforme compras de cartão vão sendo quitadas.
- Fita Visual de Projeção Mensal Empilhada:
  - Visualização de barras proporcionais nos próximos meses dividida por cor/tipo (azul para cartão, roxo para financiamento, âmbar para consórcio).
- Abas e Filtros Rápidos:
  - Filtro por tipo: "Todos", "Cartão de Crédito", "Financiamentos", "Consórcios".
  - Filtro por status: "Ativos", "Quitados/Concluídos".
- Modal Inteligente de Cadastro com Auto-complete:
  - Formulário adaptativo conforme o tipo selecionado (cartão vs financiamento vs consórcio).
  - Campo de busca inteligente com preenchimento automático a partir de transações históricas do extrato (descrição, valor e padrão de parcelas).
- Performance & Arquitetura:
  - Remoção do botão de "Detectar no Extrato" pesado da tela principal, delegando essa varredura em massa para a central `/admin` e para o pipeline automático de ingestão.
- Atualização e adição de testes em `test/cash_lens/installments_test.exs` e `test/cash_lens_web/live/installment_live_test.exs`.

Explicitamente fora de escopo (Out of Scope):
- Alteração na conciliação de faturas de cartão de crédito.
- Automação de lances de consórcio ou simulação de juros compostos avançados.

## Approach
### 1. Behavior
- A migração de banco adiciona as colunas necessárias à tabela `installment_groups`.
- O LiveView `CashLensWeb.InstallmentLive.Index` calcula os agregados (comprometimento do mês, saldo devedor e alívio em 90 dias) e renderiza os 3 cards principais.
- As abas de tipo e status filtram a listagem sem recarregar a página inteira via `live_patch`.
- O modal de novo compromisso consulta descrições recentes de transações para auto-preencher valores e padrões.

### 2. Files Touched
- `priv/repo/migrations/*_add_commitment_types_to_installment_groups.exs`: migration adicionando `commitment_type`, `interest_rate`, `credit_letter_amount`, `is_contemplated`.
- `lib/cash_lens/installments/installment_group.ex`: atualiza schema e changeset para validar os novos campos.
- `lib/cash_lens/installments.ex`: funções para calcular saldo devedor consolidado e projeção de alívio em 90 dias.
- `lib/cash_lens_web/live/installment_live/index.ex`: reestrutura a tela para suportar os 3 cards, projeção empilhada, abas de filtro e remoção do escaneamento síncrono pesado.
- `test/cash_lens_web/live/installment_live_test.exs`: testes cobrindo filtros por tipo, cards de métricas e formulário adaptativo.

### 3. Test Criteria
- `test/cash_lens_web/live/installment_live_test.exs` valida:
  - Listagem e cálculo correto dos 3 cards de topo para cartão, financiamento e consórcio.
  - Filtro por tipo via abas (`credit_card`, `financing`, `consorcio`).
  - Cadastro de financiamento e consórcio com campos específicos salvos com sucesso.
- `mix test test/cash_lens_web/live/installment_live_test.exs` passa sem falhas.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Apoio a múltiplos tipos de compromissos a prazo: Cartão de Crédito (consumo), Financiamentos (longo prazo/amortização) e Consórcios (carta de crédito e contemplação)
- [ ] 3 Cards de métricas globais no topo: Comprometimento Mensal discriminado com contagem de compras em (), Saldo Devedor Consolidado e Alívio no Fluxo de Caixa nos próximos 90 dias
- [ ] Fita de fluxo projetado mensal com barras empilhadas e proporcionais por tipo (cartão diminuindo no curto prazo e financiamento/consórcio na base)
- [ ] Abas de filtro por tipo (Todos, Cartão de Crédito, Financiamentos, Consórcios) e status (Ativos, Concluídos)
- [ ] Modal adaptável de novo compromisso com assistente de preenchimento automático a partir de transações do extrato
- [ ] Remoção da varredura pesada da tela principal, delegando detecção em lote ao /admin e ao pipeline de importação
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Simulador financeiro de amortização SAC vs Price.
- Modificações em faturas de cartão de crédito.
