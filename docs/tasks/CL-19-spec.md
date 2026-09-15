# CL-19 — Modernizar Layout Global e Menu Lateral com navegação consolidada e tema claro

## Scope
Modernização da casca de layout da aplicação (`lib/cash_lens_web/components/layouts/app.html.heex` e componentes auxiliares), estabelecendo um padrão visual limpo (Light Theme unificado) e reorganizando o menu de navegação lateral em quatro domínios temáticos claros da vida financeira. O layout substitui o antigo menu disperso com submenus sanfona confusos por uma estrutura semântica legível, menu lateral recolhível suavemente e um cabeçalho superior com atalhos de ação rápida para importação e lançamentos manuais.

Inclui:
- 4 Grupos Semânticos de Navegação na Barra Lateral:
  - Visão Geral: Painel Principal (`/`), Extrato Geral (`/transactions`), Saldos Contábeis (`/balances`), Fechamento & Comparativo (`/months`).
  - Conciliação & Importação: Central de Importação (`/imports`), Faturas de Cartão (`/statements`), Transferências (`/transfers`), Reembolsos (`/reimbursements`).
  - Planejamento: Parcelas & Consórcios (`/installments`), Previsão de Caixa (`/forecast`).
  - Cadastros & Sistema: Contas & Cartões (`/accounts`), Categorias (`/categories`), Automações & Regras (`/automation`), Banco de Dados (`/admin/db`).
- Menu Lateral Recolhível (Compact Mode):
  - Botão de recolhimento suave no topo da barra lateral para alternar entre modo completo (com textos e seções) e modo compacto (apenas ícones centrais com tooltips nativos).
- Topbar Global com Atalhos e Contexto:
  - Exibição de trilha de navegação (breadcrumb de grupo e tela ativa).
  - Indicador do mês e ano contábil de referência.
  - Ações rápidas globais sempre acessíveis: botão primário "Importar Extratos" e atalho para "Nova Transação".
- Padrão Visual Claro Unificado:
  - Background padrão `bg-[#f8fafc]`, cartões e painéis em branco com bordas sutis `border-slate-200`, tipografia `Plus Jakarta Sans` ou sistema e acentos em azul institucional `text-blue-600`.
- Atualização e adição de testes em `test/cash_lens_web/controllers/page_controller_test.exs` e layouts.

Explicitamente fora de escopo (Out of Scope):
- Alteração no conteúdo interno das páginas individuais já especificadas nas tarefas CL-4 a CL-18.
- Migrações no banco de dados.

## Approach
### 1. Behavior
- O layout `app.html.heex` envolve todas as LiveViews da aplicação.
- A rota ativa (`@current_path` ou URI detectada) aplica destaque visual de rota selecionada (`bg-blue-50 text-blue-600 font-bold`).
- O estado de recolhimento do menu lateral é persistido no navegador via LocalStorage ou controlado via classe CSS responsiva para garantir que a preferência do usuário seja respeitada na navegação.
- O Drawer mobile continua funcionando perfeitamente em telas menores através do toggle hambúrguer.

### 2. Files Touched
- `lib/cash_lens_web/components/layouts/app.html.heex`: reformula estrutura da barra lateral, topo global com atalhos e container principal.
- `lib/cash_lens_web/components/layouts/root.html.heex`: garante compatibilidade com tema claro nativo e fontes limpas.
- `assets/js/app.js`: hook ou script leve para persistência do estado recolhido da barra lateral.
- `test/cash_lens_web/controllers/page_controller_test.exs`: valida renderização dos novos links do menu e rotas consolidadas.

### 3. Test Criteria
- Testes automatizados validam:
  - Renderização dos links de navegação dos 4 grupos semânticos no layout.
  - Presença dos botões de ação rápida no cabeçalho superior.
  - Ausência de quebras de layout nas rotas principais.
- `mix test test/cash_lens_web/controllers/page_controller_test.exs` passa com 100%.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Barra lateral organizada em 4 grupos lógicos: Visão Geral, Conciliação, Planejamento e Cadastros
- [ ] Todas as 12 telas do sistema devidamente mapeadas e acessíveis a partir do menu lateral
- [ ] Suporte a alternância de menu recolhível (modo compacto por ícones)
- [ ] Topbar global com atalhos rápidos de Importar Extratos e Nova Transação
- [ ] Tema claro consistente em toda a estrutura do layout
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Migrações no banco de dados.
- Alteração nos controllers ou LiveViews internas fora da casca de layout.
