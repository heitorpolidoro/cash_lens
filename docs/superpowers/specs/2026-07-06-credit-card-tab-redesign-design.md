# Redesenho da aba de Cartão de Crédito

**Data:** 2026-07-06
**Status:** Aprovado (brainstorming)

## Problema

A aba `/credit_card_links` é uma tela de reconciliação com 6 seções empilhadas
(Pares Sugeridos, Sem Pai Encontrado, Pagamentos sem Fatura, Vinculados com
Divergência, Vinculados OK, modal). É confusa e, na prática, **não vincula nada**.

### Causa raiz do "nada casa" (diagnóstico com dados reais)

Hoje uma "fatura/lote" é definida por `{account_id, inserted_at}`. O import em
pasta processa vários arquivos e o `inserted_at` é truncado ao segundo, então
**vários arquivos (vários meses de fatura) caem no mesmo lote**.

Evidência do banco de dev:

- **Ourocard:** 1326 transações cobrindo ~19 meses, em apenas **5** `inserted_at` distintos.
- **Amazon:** 11 transações (~5 meses) num único `inserted_at`.
- **Zero** transações com `parent_transaction_id` (nenhum vínculo).

A soma de um "lote" (≈ um ano de compras) nunca iguala um pagamento mensal, logo
o matcher exato falha sempre. Corrigir o **agrupamento** é o que destrava tudo.

Causa secundária: mesmo por fatura, a soma das linhas de compra pode divergir do
"total a pagar" por saldo anterior, IOF, anuidade e estornos. Por isso vale
capturar o total oficial do arquivo.

## Objetivos

1. Agrupar transações de cartão por **fatura = arquivo importado** (robusto).
2. Fazer o matching **funcionar** no import.
3. Substituir as 6 seções por **overview de faturas → detalhe da fatura**.
4. Backfill do histórico **re-lendo os arquivos**, sem bagunçar categorias.

Fora de escopo (YAGNI): modelo completo de ciclo de fechamento configurável por
cartão (dia de fechamento/vencimento como config). O vencimento vem do PDF.

## Modelo de dados

### Nova tabela `credit_card_statements` (a "fatura")

| Campo | Tipo | Origem |
|---|---|---|
| `id` | `binary_id` (UUID) | gerado 1× por arquivo no import (= `import_batch_id`) |
| `account_id` | `binary_id` FK accounts | conta do cartão |
| `competencia` | `date` (dia 1 do mês) | derivado do vencimento |
| `due_date` | `date` nullable | parser (`statement_date` = "Vencimento") |
| `total_a_pagar` | `decimal` nullable | nova extração da linha "TOTAL DA FATURA"; fallback = soma das linhas |
| `source_file` | `string` nullable | nome do arquivo importado |
| `payment_transaction_id` | `binary_id` FK transactions nullable | pagamento vinculado |
| `inserted_at`/`updated_at` | timestamps | |

### Alteração em `transactions`

- Novo campo `import_batch_id :binary_id` (FK → `credit_card_statements.id`, nullable).
  Carimbado **uma vez por chamada de `Ingestor.import_file/3`**, imune ao
  truncamento de segundo. Substitui o agrupamento por `inserted_at`.

O `parent_transaction_id` existente continua ligando as transações-filhas ao
pagamento-pai; a fatura passa a ser a unidade de agrupamento e o
`payment_transaction_id` na fatura espelha esse vínculo em nível de fatura.

## Parser (`pdf_parser.ex`, `:bradesco_card`)

- `extract_statement_date/1` já captura o **vencimento** — reaproveitar.
- **Novo:** extrair o valor da linha "TOTAL DA FATURA" / "TOTAL PARA ..." (hoje
  usada só como marcador de fim de tabela) e retornar como `total_a_pagar`.
- `parse/2` passa a retornar `{transactions, statement_meta}` (ou struct) com
  `due_date`, `total_a_pagar`, `competencia`. Fontes sem esses dados (OFX/CSV)
  retornam `nil` → degrada com elegância (competência das datas, total = soma).

## Fluxo de importação (`ingestor.ex`)

Por arquivo, dentro de `process_imported_content`:

1. Gera `statement_id = UUID.generate()`.
2. Cria a `credit_card_statement` (se a conta é `is_credit_card`) com os metadados.
3. `insert_all` das transações com `import_batch_id = statement_id`.
4. Matching por fatura (ver abaixo) em vez de `match_batch` por `inserted_at`.

Contas não-cartão seguem o fluxo atual sem fatura.

## Matching

Reescrever `CreditCardMatcher` para operar por **fatura**:

- **Auto-vincula** quando existe um pagamento (categoria `cartao-de-credito`,
  em conta diferente do cartão, ainda sem filhos) com
  `amount == statement.total_a_pagar` (ou == soma das linhas quando não há total)
  dentro de uma **janela de data mais realista** (vencimento ± ~15 dias, em vez
  dos 5 dias atuais). Empate → não auto-vincula, marca melhor sugestão.
- **Sem casamento exato:** grava a melhor sugestão (mais próxima em valor/data),
  a fatura fica **aberta** para confirmação de 1 clique no detalhe.
- Vincular seta `parent_transaction_id` nas filhas **e** `payment_transaction_id`
  na fatura. Desvincular reverte ambos.

## Backfill (mix task de re-leitura)

`mix cash_lens.backfill_statements <caminho>` (default = `last_batch_import_path`):

- Varre a mesma estrutura de pastas `.account`.
- Por arquivo: gera `statement_id`, parseia, cria a fatura, e para cada linha
  lida **encontra a transação já existente pelo `fingerprint`** e atualiza
  **somente** `import_batch_id`.
- **Não** insere duplicatas, **não** re-categoriza, **não** re-vincula à toa
  (categorias 100% preservadas). Após stampar, roda o matching por fatura para
  popular vínculos/sugestões.
- Idempotente: rodar de novo re-agrupa sem efeitos colaterais.

## UI (`CreditCardLinkLive` → renomear para `CreditCardStatementLive`)

Rota `/credit_card_links` → `/statements` (manter redirect da antiga). Item de
menu "Cartão de Crédito".

### Overview — tabela única filtrável (opção B)

- Uma tabela com **todas as faturas** de todos os cartões.
- Colunas: Cartão · Competência · Vence · Total a pagar · Status.
- Status: ✅ vinculada · ⚠ aberta · ❗ divergente (vinculada mas soma ≠ total).
- Chips de filtro no topo: por cartão e "só abertas".
- Clicar numa linha → detalhe.

### Detalhe — bloco de pagamento em faixa no topo (opção 1)

- Cabeçalho: cartão, competência, vencimento, `source_file`, **total a pagar**
  com **soma das linhas** logo abaixo (divergência explícita, não é erro).
- **Faixa de pagamento** logo abaixo do cabeçalho (antes dos lançamentos):
  - Vinculada: verde, dados do pagamento + "Desvincular".
  - Aberta: âmbar, sugestão automática + "Vincular sugestão" / "Escolher…".
- Lista de **lançamentos** da fatura (data, descrição, categoria, valor),
  incluindo linhas de IOF/encargos quando existirem.

## Testes

- Parser: extrai `due_date` e `total_a_pagar`; fontes sem total usam fallback.
- Ingestor: cada arquivo gera uma fatura com `import_batch_id` único; transações
  recebem o id; contas não-cartão inalteradas.
- Matcher: auto-vincula em casamento exato na janela; sugere sem auto-vincular
  fora do exato; empate não vincula; unlink reverte filhas e fatura.
- Backfill: stampa `import_batch_id` em linhas existentes por fingerprint,
  preserva categorias, idempotente.
- LiveView: overview filtra por cartão/status; detalhe vincula/desvincula.

## Migração / rollout

1. Migration: cria `credit_card_statements`, adiciona `transactions.import_batch_id`.
2. Deploy do parser/ingestor/matcher/UI.
3. Rodar `mix cash_lens.backfill_statements` para popular o histórico.
4. Código de reconciliação antigo (`list_credit_card_link_suggestions`,
   `orphan_batches` por `inserted_at`, etc.) é removido/substituído.
