# TODO - CashLens: Sistema de Controle Financeiro Inteligente

## 1. Interface (UI/UX) - PRIORIDADE 🎨
- [ ] Definir Design System (Cores, Tipografia, Componentes Base).
- [ ] **Dashboard Principal:**
    - [ ] Gráficos de Gastos por Categoria (Pizza/Donut).
    - [ ] Evolução de Saldo Mensal (Linha/Barras).
    - [ ] Widget de "Próximas Faturas/Parcelas".
- [ ] **CRUD de Contas:**
    - [ ] Cadastro de Bancos, Carteiras e Cartões de Crédito.
    - [ ] Gestão de Saldos Iniciais.
- [ ] **Módulo de Lançamentos:**
    - [ ] Tela de importação de extratos (Drag & Drop).
    - [ ] Listagem de transações com filtros avançados.
- [ ] **Módulo de Financiamentos & Parcelados:**
    - [ ] Cadastro de compras parceladas com projeção futura.
    - [ ] Visualização de "Dívida Total" vs "Parcela Mensal".
- [ ] **Gestão de Reembolsos:**
    - [ ] Marcar despesas como "A Reembolsar" (ex: despesas de trabalho).
    - [ ] Controle de status: Pendente -> Recebido.

## 2. Ingestão de Dados (Multi-formato) 📥
- [ ] Implementar parser para arquivos estruturados (CSV, OFX).
- [ ] Implementar motor de OCR/LLM (Ollama) para PDFs e Imagens.
- [ ] Normalização de dados para o schema único.

## 3. Inteligência Artificial e Classificação 🧠
- [ ] Integrar o serviço de ML (`ml/main.py`) para categorização automática.
- [ ] Treinamento contínuo baseado nas correções manuais da UI.

## 4. Novas Funcionalidades Sugeridas 🚀
- [ ] **Gestão de Assinaturas:** Listagem de recorrências (Netflix, Spotify, Academia).
- [ ] **Metas Financeiras:** Barra de progresso para objetivos (Viagens, Reserva de Emergência).
- [ ] **Segurança:** Sistema de Login e proteção de dados sensíveis.
- [ ] **Exportação:** Gerar relatórios em PDF ou Excel.

## 5. Backend e Infraestrutura ⚙️
- [ ] API robusta para suportar todas as operações de CRUD.
- [ ] Banco de dados MongoDB para persistência.
- [ ] Containerização total com Docker.
- [ ] Implementar um renderizador de Markdown robusto no frontend (substituindo o placeholder no assets/js/app.js)
