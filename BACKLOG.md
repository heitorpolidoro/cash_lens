# CashLens Project Backlog & Engineering Guidelines

Este arquivo consolida as diretrizes estratégicas, decisões arquiteturais e o backlog de tarefas do projeto CashLens.

## 🏛️ Diretrizes e Decisões Arquiteturais (Estratégico)

- **Stack de Dados**: O PostgreSQL é o banco de dados definitivo. Planos anteriores de migração para MongoDB foram descartados. O sistema deve permanecer fortemente relacional.
- **Modelo Contábil**: O modelo de 'saldos encadeados' é central, mas reconhecido como um risco de performance. Qualquer alteração no core de `Accounting` deve prever snapshots para evitar processamento linear exaustivo.
- **Escalabilidade**: O sistema atual é single-user. Projetar novas funcionalidades (como Auth e Multi-tenancy) com a possibilidade de expansão para SaaS em mente.
- **Evolução de Ingestão**: A transição de parsers baseados em Regex/Texto para modelos baseados em IA (LLM/Ollama) é a direção estratégica para lidar com a complexidade de extratos bancários.

---

---

## 🟡 Prioridade 2: Core Business e Escalabilidade (Curto Prazo)
*Foco: Aumentar o valor do produto para o usuário e otimizar o sistema para suportar volume de dados.*

1. **Ingestão de Dados e Padronização**
   - [ ] **Tratamento de Erros de Ingestão**: Substituir crashes (`Date.new!`) por erros graciosos e implementar estado de "Quarentena".

---

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

-----------
- [ ] Cria lógica de conta parcelada
- - Incluir a informaçào de parcelas futuras

- [ ] Corrigir os salários antes de receber da Avant
- [ ] Conferir se todos as consultas e cirurgia estào marcadas como reembolso
