# Importar transações via Pluggy (Open Finance)

**Data:** 2026-07-31
**Status:** Aprovado (brainstorming)

## Problema

Hoje o cash_lens só importa transações de arquivos (CSV/OFX/PDF/TXT) soltos
manualmente numa pasta. A Pluggy (agregador de Open Finance) já está
conectada à conta real do usuário (Banco do Brasil) e expõe as mesmas
transações via API, sem precisar baixar/soltar arquivo nenhum. Queremos um
caminho de importação alternativo, via API, que conviva com o import por
arquivo já existente sem duplicar nem conflitar dados.

## Contexto técnico da API Pluggy

- Autenticação: `POST /auth` com `clientId`/`clientSecret` (guardados em
  `.env`, nunca commitados) retorna um `apiKey` que expira em 2h — deve ser
  gerado a cada sincronização, não guardado entre execuções.
- A Pluggy **não** tem endpoint para listar "items" (conexões) existentes —
  é uma decisão deles por segurança. O `itemId` precisa ser guardado por
  quem integra (nós).
- `GET /accounts?itemId=...` lista as contas dentro de um item — isso
  funciona normalmente, confirmado contra a conexão real do BB.
- `GET /v2/transactions?accountId=...` lista transações de uma conta
  (endpoint antigo `GET /transactions` foi descontinuado — retorna HTTP
  410). Sem parâmetro `pageSize` (rejeitado pela API); a paginação é por
  cursor, campo `next` na resposta.
- **Convenção de sinal difere por tipo de conta** (verificado na
  documentação, não é chute):
  - Conta `BANK`: `amount` sempre positivo; `type` (`"DEBIT"` ou
    `"CREDIT"`) indica a direção.
  - Conta `CREDIT` (cartão): `amount` já vem com sinal, mas **invertido**
    em relação à convenção do cash_lens (positivo = compra/débito na
    Pluggy; o cash_lens usa negativo = despesa).
- Conta `CREDIT` traz um objeto `creditData` com `balanceDueDate` (data de
  vencimento, `yyyy-mm-dd`), `balanceCloseDate` (data de fechamento) e o
  saldo devedor no campo `balance` do objeto pai da conta.

## Modelo de dados

Duas tabelas novas:

**`pluggy_items`**
- `id` (uuid, pk)
- `item_id` (string, o UUID que a Pluggy usa — vem do DevTools do painel,
  não de uma API de listagem)
- `label` (string — nome livre pro usuário identificar, ex: "Open Finance
  BB")
- timestamps

**`pluggy_account_links`**
- `id` (uuid, pk)
- `pluggy_item_id` (fk → `pluggy_items`)
- `pluggy_account_id` (string — o `id` da conta na Pluggy)
- `pluggy_account_name` (string — nome que a Pluggy retornou, ex: "BANCO DO
  BRASIL S/A")
- `pluggy_account_type` (string — `"BANK"` ou `"CREDIT"`)
- `account_id` (fk nullable → `accounts` do cash_lens — nulo até o usuário
  escolher no combo)
- `last_synced_at` (datetime nullable — data/hora da última importação de
  transações bem-sucedida desta conta)
- timestamps
- índice único em `(pluggy_item_id, pluggy_account_id)` — sincronizar de
  novo atualiza a linha existente em vez de duplicar

Um campo novo em `transactions`:
- `pluggy_category` (string, nullable) — a categoria que a Pluggy sugeriu
  pra transação, guardada como dado histórico. Não tem uso ativo nesta
  versão (sem mapeamento pras categorias do cash_lens); é só um hint pra
  possível uso futuro.

## Telas

### `/pluggy` — cadastro e mapeamento

- Formulário simples: campo de texto pro `itemId` + campo de texto pro
  `label` → cria um `pluggy_items`.
- Lista dos items cadastrados, cada um com um botão **"Sincronizar
  contas"**: chama `GET /accounts?itemId=...`, faz upsert em
  `pluggy_account_links` (contas novas entram com `account_id` nulo; contas
  já vistas só atualizam nome/tipo/saldo exibido, sem mexer no
  `account_id` já escolhido).
- Abaixo de cada item, uma tabela das contas Pluggy vinculadas a ele:
  nome, tipo, saldo (só exibição, não persistido) e um `<select>` com as
  contas do cash_lens (`Accounts.list_accounts()`) — salvar o select
  atualiza o `account_id` da linha.

### `/transactions` — botão "Importar do Pluggy"

Ao lado dos botões "Importar" e "Importar em Lote" já existentes. Um único
clique roda a sincronização de **todas** as `pluggy_account_links` que já
têm `account_id` preenchido (as sem mapeamento são ignoradas silenciosamente
— o usuário resolve isso em `/pluggy`). Para cada uma:

1. Autentica (`POST /auth`) uma vez para todo o lote.
2. Busca transações via `GET /v2/transactions?accountId=...&from=...`,
   paginando pelo cursor `next` até acabar.
3. Para cada transação: normaliza o sinal (regra abaixo), monta os campos
   e chama `CashLens.Transactions.create_transaction/1` — a mesma função
   que a tela de "Atualizar com Rendimentos" já usa. Isso reaproveita de
   graça: dedupe por fingerprint (reimportar não duplica), matching de
   transferência, matching de pagamento de cartão, e recálculo de saldo.
4. Se a conta é do tipo `CREDIT`: depois das transações, busca a conta de
   novo (`GET /accounts?itemId=...`, já teremos os dados) e faz
   find-or-update de uma `credit_card_statements` para a competência atual
   (ver seção abaixo).
5. Atualiza `last_synced_at` da `pluggy_account_link` para agora, só se o
   passo 2-4 terminou sem erro.
6. Mostra um resumo (flash): quantas transações novas por conta, quantas já
   existiam (dedupe), e falhas por conta (uma conta falhando não deve
   travar as outras).

## Conversão de sinal

- `pluggy_account_type == "BANK"`: `amount_cash_lens = if type == "DEBIT",
  do: -amount_pluggy, else: amount_pluggy` (usando o `amount` sempre
  positivo da Pluggy e o campo `type` para a direção).
- `pluggy_account_type == "CREDIT"`: `amount_cash_lens = -amount_pluggy`
  (inverte o sinal, já que a Pluggy usa positivo = despesa pra cartão).

Isto é a parte mais arriscada de errar silenciosamente (inverteria
receita/despesa nos relatórios) — leva testes dedicados antes de qualquer
outra coisa na implementação.

## Fatura de cartão via Pluggy (evitar duplicar com o import por TXT)

Já que TXT e Pluggy vão **coexistir** pro Ourocard, antes de criar uma
`credit_card_statements` nova para `(account_id, competencia)`, primeiro
busca se já existe uma para esse par — se existir, **atualiza** (`due_date`,
`total_a_pagar`) em vez de inserir outra. Essa trava não existe hoje em
lugar nenhum do código (nem para o import por arquivo) — é uma
funcionalidade nova que corrige de quebra o risco de duplicação de fatura
que já foi limpo manualmente à mão várias vezes nesta sessão.

Fonte dos dados da fatura: `creditData.balanceDueDate` → `due_date`;
`creditData.balanceCloseDate` combinado com a lógica já existente em
`CreditCards.competencia_for/3` → `competencia`; `balance` da conta →
`total_a_pagar`.

## Janela de sincronização

- Se `last_synced_at` é nulo (primeira sincronização desta conta): busca
  os últimos 90 dias.
- Se `last_synced_at` está preenchido: busca desde essa data até hoje.
- O `import` **não** força a Pluggy a atualizar o item antes de ler (não
  chama `PATCH /items/{id}`) — lê o que já estiver sincronizado do lado da
  Pluggy no momento do clique. Forçar atualização fica de fora desta
  versão (ver Não-objetivos).

## Não-objetivos (YAGNI)

- Sincronização automática/agendada (Oban) — só botão manual por enquanto.
- Forçar a Pluggy a atualizar o item antes de ler (`PATCH /items/{id}`).
- Usar `pluggy_category` para sugerir categoria automaticamente — só
  armazenamento por enquanto.
- Suporte a outros tipos de conta Pluggy além de `BANK`/`CREDIT` (ex.
  investimentos) — os campos de mapeamento existem, mas o cálculo de sinal
  e o fluxo de fatura só cobrem esses dois tipos; outro tipo cai em erro
  explícito, não em comportamento silencioso incorreto.
- Editar/remover `pluggy_items` ou `pluggy_account_links` pela UI (só
  criar) — se precisar desfazer um mapeamento errado, é direto no banco por
  enquanto.
- Renovação/gestão do consentimento Pluggy (`consentExpiresAt`) — fora de
  escopo, tratado manualmente se/quando expirar.

## Testes

- Conversão de sinal: `BANK`+`DEBIT` → negativo; `BANK`+`CREDIT` →
  positivo; `CREDIT` (Pluggy positivo) → negativo no cash_lens.
- Reimportar as mesmas transações não duplica (dedupe por fingerprint via
  `create_transaction/1`).
- Sincronizar duas vezes a mesma competência de cartão atualiza a fatura
  existente, não cria uma segunda.
- Sincronização com `last_synced_at` nulo usa janela de 90 dias; com
  `last_synced_at` preenchido usa essa data como início.
- Conta Pluggy sem `account_id` mapeado é ignorada na importação (não
  gera erro, só não entra no lote).
- Uma conta falhando durante a importação em lote não impede as demais de
  serem processadas; o resumo final relata o que falhou.
- Sincronizar contas de um item duas vezes não duplica
  `pluggy_account_links` (índice único cobre isso) e preserva o
  `account_id` já escolhido.

## Arquivos

- `priv/repo/migrations/` — duas migrações novas (`pluggy_items`,
  `pluggy_account_links`) + uma para `transactions.pluggy_category`.
- `lib/cash_lens/pluggy.ex` — contexto `CashLens.Pluggy` (CRUD de items e
  account links).
- `lib/cash_lens/pluggy/item.ex`, `lib/cash_lens/pluggy/account_link.ex` —
  schemas.
- `lib/cash_lens/pluggy/client.ex` — chamadas HTTP puras à API Pluggy
  (`auth/0`, `list_accounts/2`, `list_transactions/3`), usando `Req` (já é
  dependência do projeto).
- `lib/cash_lens/pluggy/sync.ex` — orquestra a importação: normalização de
  sinal, chamada a `Transactions.create_transaction/1`, find-or-update de
  `credit_card_statements`, atualização de `last_synced_at`.
- `lib/cash_lens_web/live/pluggy_live/index.ex` — tela `/pluggy`.
- `lib/cash_lens_web/live/transaction_live/index.ex` — botão novo
  "Importar do Pluggy" e handler correspondente.
- Testes correspondentes em `test/cash_lens/pluggy_test.exs`,
  `test/cash_lens/pluggy/sync_test.exs`,
  `test/cash_lens_web/live/pluggy_live/index_test.exs`.
