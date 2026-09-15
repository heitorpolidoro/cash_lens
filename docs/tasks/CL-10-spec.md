# CL-10 — Unificar formulário manual, edição e modal de confirmação de exclusão de transações

## Scope
Substituição das páginas cheias legadas `/transactions/new`, `/transactions/:id/edit` e `/transactions/:id` por modais LiveView sobrepostos diretamente ao extrato de transações. Os modais preservam a posição de scroll do usuário e a URL compartilhável via LiveView `live_patch`. O formulário é simplificado para derivar receita vs despesa exclusivamente pelo sinal matemático digitado no valor (- para despesas/saídas, positivo ou sem sinal para receitas/entradas), com feedback de cores dinâmico em tempo real. A exclusão de transações ganha um modal de confirmação seguro antes de remover o registro.

Inclui:
- Unificação das rotas de formulário:
  - `/transactions/new` abre o modal de criação sobreposto a `TransactionLive.Index`.
  - `/transactions/:id/edit` abre o modal de edição sobreposto.
  - `/transactions/:id` (show/detalhe) abre modal de inspeção com detalhes completos.
  - Fechar o modal via ESC, clique no backdrop ou botão de fechar faz `patch={~p"/transactions"}` preservando o scroll.
- Entrada de Valor Direta por Sinal:
  - Eliminação de toggles ou radio buttons redundantes de "Receita / Despesa".
  - Digitação com sinal negativo (`-`) formata visualmente em vermelho com label dinâmico "Despesa / Saída".
  - Digitação sem sinal ou positivo (`+`) formata visualmente em verde com label "Receita / Entrada".
  - Persiste o valor em centavos / decimal diretamente no banco respeitando o sinal.
- Modal de Confirmação de Exclusão:
  - O clique no ícone de lixeira não executa `phx-click="delete"` imediatamente nem usa `data-confirm` nativo do navegador.
  - Abre um modal LiveView elegante destacando o valor, descrição, conta e data da transação a ser excluída, com aviso de impacto contábil e botão de confirmação destrutiva.
- Rastreabilidade de Vínculos na Edição:
  - Quando a transação possui vínculos (reembolso ativo, chave de transferência para outra conta ou conciliação com fatura de cartão), exibe uma seção colapsável informando os relacionamentos que serão afetados caso alterada.
- Atualização e adição de testes em `test/cash_lens_web/live/transaction_live_test.exs`.

Explicitamente fora de escopo (Out of Scope):
- Modificação dos dados das transações além dos campos editáveis padrão (data, descrição, valor, conta, categoria, notas).
- Alteração nos parsers ou na lógica de deduplicação de transações importadas.

## Approach
### 1. Behavior
- No `TransactionLive.Index`, a macro de rotas ou `handle_params/3` verifica a ação (`:new`, `:edit`, `:show`) e carrega o modal correspondente como um LiveComponent (`CashLensWeb.TransactionLive.FormComponent` ou similar).
- O evento `validate` do formulário processa o valor digitado, identifica o sinal (`-` vs `+`), e atualiza as classes CSS e textos explicativos de feedback instantaneamente.
- O clique de exclusão emite `confirm_delete` passando o ID da transação, definindo `@deleting_transaction` e exibindo o modal de confirmação.
- A confirmação de exclusão chama `Transactions.delete_transaction/1`, remove a transação do stream e fecha o modal.

### 2. Files Touched
- `lib/cash_lens_web/router.ex`: ajusta as rotas filhas de transações para apontarem para as ações de `TransactionLive.Index` (`:new`, `:edit`, `:show`).
- `lib/cash_lens_web/live/transaction_live/index.ex`: adiciona handlers de `handle_params`, modais de formulário e modal de exclusão.
- `lib/cash_lens_web/live/transaction_live/form_component.ex`: refatora o formulário manual com a nova lógica de valor por sinal e suporte a vínculos.
- `test/cash_lens_web/live/transaction_live_test.exs`: adiciona testes para abertura e fechamento de modais, validação de valor por sinal e fluxo de confirmação de exclusão.

### 3. Test Criteria
- `test/cash_lens_web/live/transaction_live_test.exs` valida:
  - Abertura dos modais em `/transactions/new` e `/transactions/:id/edit`.
  - Conversão correta do sinal do valor em despesa vs receita.
  - Exibição do modal de confirmação antes da exclusão de uma transação.
  - Exclusão bem-sucedida apenas após a confirmação no modal.
- `mix test test/cash_lens_web/live/transaction_live_test.exs` passa com 100%.
- `mix quality_check` passa com 0 erros e 0 avisos.

## Expected Results
- [ ] Rotas /transactions/new, /transactions/:id/edit e /transactions/:id funcionam como modais LiveView sobrepostos sem quebrar o estado de scroll do extrato
- [ ] Campo de valor aceita digitação direta com sinal (- para débito/despesa, sem sinal/+ para crédito/receita) com feedback visual de cores e texto auxiliar dinâmico em tempo real
- [ ] Remoção de botões ou chaves redundantes de tipo (Receita vs Despesa), gravando diretamente o valor numérico com sinal no modelo do banco de dados
- [ ] Exclusão de transação aciona modal de confirmação com exibição destacada da descrição, data, conta e valor antes de efetivar a remoção
- [ ] Edição de transação exibe bloco expansível de rastreabilidade de vínculos (reembolsos ou conciliações bancárias) quando aplicável
- [ ] Suite de testes passa com mix quality_check

## Out of Scope
- Edição em lote de transações.
- Alterações em regras de categorização automática.
