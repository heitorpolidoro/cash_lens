# Design: Auto-categorizar parcelas ao agrupar

**Data:** 2026-06-05
**Módulo alvo:** `lib/cash_lens/installments.ex`

## Objetivo

Quando o sistema agrupa as parcelas de uma compra parcelada, preencher automaticamente a categoria das parcelas que ainda não têm categoria. Nunca sobrescrever categorias existentes.

## Contexto atual

- `AutoCategorizer.categorize/1` (`lib/cash_lens/transactions/auto_categorizer.ex`) já roda em cada transação no import (`Ingestor.prepare_transaction_entry/4`), casando por palavras-chave de categoria, regras de transferência e regras especiais. Roda sobre a descrição **crua** (ex.: `EC *9PRODUTOS PARC 08/10 MARING`).
- A detecção/agrupamento de parcelas roda depois, em `Installments.detect_and_apply/1` → `apply_installment_group/2` → `apply_present_parcels/4` → `link_and_clean/4`. O `link_and_clean` limpa a descrição para o "merchant base" (`detection.base`, ex.: `EC *9PRODUTOS`) via `Repo.update_all` (preserva `fingerprint`/`dedup_key`).
- `Transaction` tem `belongs_to :category` (`category_id`). Não há flag de origem (manual vs automática).

## Comportamento

Após `link_and_clean` linkar e limpar todas as parcelas presentes de um grupo, executar `fill_group_categories/3`:

1. **Determinar a categoria do grupo:**
   - **Herança:** entre as transações atuais do grupo que têm `category_id`, escolher a mais frequente (mode). (Empate: resultado arbitrário porém estável — caso raro.)
   - **Fallback:** se nenhuma transação do grupo tem categoria, chamar `AutoCategorizer.categorize(%{description: base, account_id: account_id})` (descrição **limpa**) e extrair `:category_id` do resultado.
2. **Aplicar só nas vazias:** se a categoria do grupo for não-nil, `Repo.update_all` nas transações do grupo onde `category_id IS NULL`, setando `category_id`. Transações que já têm categoria ficam intocadas.
3. Se nem herança nem fallback resultarem em categoria, não faz nada.

`account_id` para o fallback: o da primeira parcela presente (todas do grupo são da mesma conta de cartão).

## Restrições / fora de escopo

- **Nunca sobrescreve** categoria existente (manual ou automática).
- **Não** recalcula `fingerprint`/`dedup_key` (usa `update_all`, como a re-datação).
- **Não** altera saldos (categoria não afeta saldo) — sem rebuild adicional.
- **Não** mexe no `reimbursement_status` (já tratado no import).
- **Não** adiciona campo de categoria no schema do grupo (a herança entre irmãs cobre).

## Fluxo de dados

`detect_and_apply` → por grupo: `apply_installment_group` → `apply_present_parcels` (linka/limpa parcelas) → **novo** `fill_group_categories(group, base, present)` → recarrega transações do grupo, calcula categoria, preenche vazias.

## Erros / bordas

- Grupo sem nenhuma categoria e sem match de keyword → permanece sem categoria.
- Parcela já categorizada → preservada.
- `AutoCategorizer.categorize/1` pode não retornar `:category_id` (retorna o map sem a chave) → tratado como nil.

## Testes

`test/cash_lens/installments_apply_test.exs` (ou novo arquivo de teste de contexto):
- Grupo com uma parcela categorizada + uma vazia → a vazia herda a categoria da irmã.
- Grupo todo vazio cuja descrição limpa casa com keyword de categoria → todas as vazias recebem a categoria via fallback.
- Parcela com categoria preexistente **não** é sobrescrita, mesmo com irmã de categoria diferente.
- Grupo sem categoria e sem match → todas seguem sem categoria.
