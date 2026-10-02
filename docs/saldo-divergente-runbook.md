# Runbook — conta com saldo divergente

Como apurar quando o saldo de uma conta no Cash Lens não bate com o do banco.
Escrito a partir do caso real do **BB Rende Fácil** em 02/10/2026.

> Este documento é um registro vivo: cada divergência apurada ganha uma entrada
> em **Histórico de ocorrências**, no fim.

---

## 1. Antes de tudo: a cadeia de saldos está defasada ou os lançamentos estão errados?

É a primeira bifurcação, e ela decide todo o resto. "Recalcular saldos" não
conserta dado errado.

```sql
-- Saldo que a cadeia afirma, contra o saldo que as transações produzem.
select a.name,
       (select final_balance from balances b
         where b.account_id = a.id order by b.year desc, b.month desc limit 1) as cadeia,
       a.balance + coalesce(sum(t.amount), 0) as pelas_transacoes
from accounts a left join transactions t on t.account_id = a.id
where a.name = 'NOME DA CONTA'
group by a.id, a.name;
```

- **Os dois números diferem** → a cadeia está defasada. Reconstrua:
  `CashLens.Accounting.rebuild_account_balances(account_id)`.
- **Os dois são iguais e ambos divergem do banco** → o problema está nos
  lançamentos. Siga para o passo 2. *Foi este o caso em 02/10/2026.*

## 2. Procure lançamentos duplicados

```sql
select date, amount, count(*) as copias,
       string_agg(distinct description, ' || ') as descricoes,
       string_agg(distinct inserted_at::date::text, ', ') as importados
from transactions
where account_id = 'UUID DA CONTA'
group by date, amount having count(*) > 1
order by date desc;
```

**Mesma data e mesmo valor não provam duplicação** — duas compras iguais no
mesmo dia existem. O que prova é o conjunto: descrições que diferem só por um
sufixo, somado a datas de importação diferentes.

## 3. Confirme pela `dedup_key`

A chave de deduplicação **inclui a descrição**:

```
<account_id>|<data>|<hora>|<valor em centavos>|<DESCRIÇÃO EM MAIÚSCULAS>
```

```sql
select id, inserted_at::date, dedup_key
from transactions
where account_id = 'UUID' and date = 'AAAA-MM-DD' and amount = -0.00;
```

Se as chaves diferem **apenas no trecho final**, a descrição mudou entre uma
importação e outra e a deduplicação não teve como reconhecer. É o defeito.

## 4. Verifique as DUAS pernas antes de apagar

Transferências geram um par ligado por `transfer_key`. Apagar só um lado deixa a
conta contrária errada.

```sql
select t.id, a.name, t.date, t.description, t.amount, t.source,
       t.inserted_at::date, t.transfer_key
from transactions t join accounts a on a.id = t.account_id
where t.transfer_key in (select transfer_key from transactions where id = 'UUID DA LINHA');
```

Apague **o par inteiro da importação mais recente**, preservando o par antigo e
completo. Guarde um `select *` das linhas antes — a exclusão não tem desfazer.
Depois, reconstrua a cadeia das duas contas.

## 5. O que fazer com o que sobrar sem explicação

Se após remover as duplicatas ainda houver diferença, **não a dissolva num
ajuste silencioso**. Registre o valor e a hipótese aqui, no histórico. Um ajuste
sem registro vira um erro que ninguém mais consegue reabrir.

---

## Causa-raiz conhecida

**O mesmo extrato baixado duas vezes, com a coluna `Detalhes` preenchida de
formas diferentes.**

Nos extratos do BB, `bb_row_description/2` junta `Lançamento` e `Detalhes`
descartando os vazios. O mesmo lançamento gera descrições distintas conforme o
`Detalhes` esteja preenchido ou não:

```
< "31/08/2026","BB Rende Fácil","Rende Facil","9903","4.320,00","Entrada"
> "31/08/2026","BB Rende Fácil","",          "9903","4.320,00","Entrada"
```

→ `"BB Rende Fácil - Rende Facil"` contra `"BB Rende Fácil"`.

Como a descrição entra na `dedup_key`, as duas linhas passam como transações
diferentes. Os arquivos também têm hashes distintos, então ambos são importados
sem reclamação.

**Sinal de alerta na pasta monitorada:** o mesmo mês presente sob dois nomes,
por exemplo `extrato_bb-cc-2026-08.csv` e `Extrato conta corrente - 082026.csv`.

---

## Linha de base — 02/10/2026

Última transação e saldo de cada conta ativa, logo após a remoção da duplicata.
Compare contra este quadro quando uma nova divergência aparecer: a conta cuja
**última data** ou **data de importação** destoa é por onde começar.

| Banco | Conta | Última transação | Linhas | Saldo calculado | Última importação |
|---|---|---|---|---|---|
| Banco do Brasil | BB RF LP High | 2026-02-03 | 5 | 26,76 | 2026-07-02 |
| Banco do Brasil | BB RF Simples Cashback | — | 0 | 617,82 | — |
| Banco do Brasil | BB Rende Fácil | 2026-09-30 | 412 | 17.990,07 | 2026-10-02 |
| Banco do Brasil | Conta Corrente | 2026-09-30 | 2247 | 0,00 | 2026-10-02 |
| Banco do Brasil | Ourocard | 2026-09-02 | 1365 | −2.757,50 | 2026-09-22 |
| Bradesco | Amazon | 2026-07-04 | 14 | −246,23 | 2026-08-11 |
| Bradesco | Amex | 2026-07-05 | 69 | −2.330,28 | 2026-07-21 |
| Bradesco | Conta Corrente | 2026-09-23 | 153 | 57,04 | 2026-10-02 |
| Mercado Pago | Cartão de Crédito | 2026-07-06 | 15 | 96,59 | 2026-08-11 |
| Mercado Pago | Conta Corrente | 2026-09-30 | 428 | 91,57 | 2026-10-02 |

Saldo calculado = `accounts.balance` + soma das transações. Não inclui ajuste
manual feito depois desta data.

Para regerar o quadro:

```sql
select a.bank, a.name, max(t.date) as ultima_transacao, count(t.id) as linhas,
       a.balance + coalesce(sum(t.amount), 0) as saldo_calculado,
       max(t.inserted_at)::date as ultima_importacao
from accounts a left join transactions t on t.account_id = a.id
where a.is_closed = false
group by a.id, a.bank, a.name order by a.bank, a.name;
```

### Pontos de atenção neste retrato

- **Conta Corrente (BB) fecha em 0,00.** Valor exato demais para ser coincidência;
  provavelmente artefato de reconciliação, já observado antes. Não apurado.
- **BB Rende Fácil tem duas procedências.** Até 17/07/2026 as linhas vieram de
  uma carga histórica de 356 registros, importada em 02/07/2026 de um extrato
  próprio que **não está mais na pasta monitorada**. Depois dessa data, só
  espelhos de transferência da conta corrente. Os extratos da conta corrente
  **não contêm** as movimentações do Rende Fácil de 2025, então o saldo dessa
  conta **não é reconstituível** a partir das fontes disponíveis hoje.
- **Contas sem importação recente** (Amazon, Amex, Cartão MP, BB RF LP High)
  têm saldo congelado na última carga; divergência nelas é esperada.

---

## Histórico de ocorrências

### 02/10/2026 — BB Rende Fácil

**Sintoma.** Saldo no app 12.487,10; saldo real informado pelo operador
19.229,80. Diferença de 6.742,70.

**Apuração.** A cadeia não estava defasada — conferia exatamente com as
transações. A importação do dia trouxe 7 linhas, das quais uma era duplicata:
21/09, −5.502,97, já presente desde a importação de 22/09 com a descrição sem o
sufixo `- Rende Facil`. A duplicação atingiu **as duas pernas** da transferência.

**Ação.** Removidas as duas linhas da importação de 02/10, preservando o par de
22/09:

| id | conta | valor | importada em |
|---|---|---|---|
| `92747c51-9feb-446c-814b-dd29e226f2ab` | Conta Corrente | +5.502,97 | 2026-10-02 |
| `ff03f453-16fe-4e3b-ab94-b8298a87dba0` | BB Rende Fácil | −5.502,97 | 2026-10-02 |

Cadeias reconstruídas. Rende Fácil passou a 17.990,07.

**Em aberto.** Restam **1.239,73** sem explicação (17.990,07 contra os 19.229,80
informados). Não há nenhuma transação com esse valor na base e não há lançamento
de outubro em nenhuma conta do BB — o extrato de outubro ainda não foi baixado.
Hipótese não verificada: movimento real ainda não importado. O saldo será
corrigido manualmente pelo operador; o ajuste deve ser registrado aqui.

**Outras contas afetadas pelo mesmo defeito**, agrupando por data e valor —
números indicativos, não auditados linha a linha:

| Conta | Grupos | Impacto |
|---|---|---|
| Conta Corrente (BB) | 36 | +29.833,84 |
| BB Rende Fácil | 5 | −12.022,67 |
| Ourocard | 13 | −1.197,41 |
| Amex | 2 | −221,05 |
