# Projeto A — Parser TXT do Ourocard

**Data:** 2026-07-07
**Status:** Aprovado (brainstorming)

## Problema

A conta Ourocard importa via **OFX**, que não carrega **Vencimento** nem um
**"total a pagar"** real. Hoje o total vem de um contorno (o saldo `LEDGERBAL`
do OFX), que na verdade é o saldo corrente/anterior, não o valor do boleto do
mês. Sem Vencimento, o Ourocard também fica de fora do detector "sem Vencimento
= não-boleto" que o Projeto B (rollover de fatura pendente) precisa.

O BB exporta a mesma fatura em **TXT**, um formato de texto plano e regular que
traz tudo limpo:

```
Vencimento      : 16.07.2026
Total da fatura : R$ 11.938,58
Pagamento mínimo: R$ 1.790,79
...
15.06.2026SCHOOL OF ROCK         SAO JOSE DOS  BR              537,82        0,00
16.06.2026PGTO DEBITO CONTA 5899 000009516  200211          -14.391,19        0,00
         SubTotal                                           7.827,48        0,00
         Total                                             11.938,58        0,00
```

## Objetivo

Substituir o OFX pelo TXT no Ourocard, obtendo **Vencimento + total reais**, e
tornar o detector de boleto uniforme para todos os cartões. Escopo restrito ao
parsing/migração; o rollover de pendentes é o Projeto B (spec seguinte).

## Não-objetivos (YAGNI)

- Categorias do BB (Educação, Restaurantes…): descartadas — usa o
  auto-categorizador existente.
- Split por portador (HEITOR / LIDIANE), `Pagamento mínimo`: não persistidos.
- Coexistência OFX + TXT: o TXT **substitui** o OFX no Ourocard.

## Parser — `CashLens.Parsers.OurocardTXTParser`

`parser_type: "ourocard_txt"`.

### Regra de transação

Uma linha é transação **se e somente se começa com uma data `DD.MM.YYYY`**.
Cabeçalhos, rótulos de categoria/portador (`Educação`, `1 - HEITOR…`),
`SALDO FATURA ANTERIOR`, `SubTotal`, `Total` e separadores **não** têm data no
início e são ignorados naturalmente. Nenhuma lista de exclusão frágil.

### Extração por linha

Regex por linha (conteúdo em latin1 → convertido a UTF-8 como o ingestor já faz):

```
^(\d{2}\.\d{2}\.\d{4})(.+?)\s+(-?[\d.]+,\d{2})\s+-?[\d.]+,\d{2}\s*$
```

- `date` = grupo 1 (`DD.MM.YYYY`).
- `description` = grupo 2, com espaços múltiplos colapsados em um só e trim.
  Mantém cidade/país e o trecho `PARC 05/06` (o `InstallmentDetector` existente
  já extrai parcelas da descrição — sem trabalho novo).
- `amount` = grupo 3 (valor R$, penúltima coluna; a última é `Valor US$`,
  sempre `0,00`), parseado como Decimal.

### Convenção de sinal

O TXT traz **compra positiva** e **crédito negativo**. O app usa o contrário
(compra negativa, pagamento/crédito positivo). Logo: `amount_armazenado =
Decimal.negate(valor_txt)`.
- Compra `537,82` → `-537,82`.
- `PGTO DEBITO CONTA -14.391,19` → `+14.391,19` (pagamento recebido = crédito).

### O que vira transação

- **Inclui:** todas as linhas de compra (todas as seções de categoria) e as
  linhas de `Pagamentos/Créditos` (pagamento recebido, estornos) — são
  movimentos reais do cartão, como o OFX já trazia.
- **Exclui:** `SALDO FATURA ANTERIOR` (saldo carregado, não movimento) — já cai
  fora por não ter data no início.

## Metadados da fatura — `extract_statement_meta/1` (TXT)

```elixir
%{
  due_date:      parse Vencimento ("Vencimento      : 16.07.2026"),
  total_a_pagar: parse "Total da fatura : R$ 11.938,58",
  competencia:   Date.beginning_of_month(due_date)
}
```

Ligado no `Ingestor.statement_meta/2`, que passa a despachar por extensão:
`.pdf → PDFParser`, `.ofx → OFXParser`, `.txt → OurocardTXTParser`, senão nils.

## Roteamento

- `Ingestor.parse(content, "ourocard_txt") → OurocardTXTParser.parse/1`.
- `Ingestor.expected_extensions("ourocard_txt") → [".txt"]`.
- `DirectoryImporter` roteia arquivos `.txt` para contas com esse parser.
- A conta Ourocard troca `parser_type`: `ourocard_ofx` → `ourocard_txt`.

## Migração (limpa, uma vez)

Executada como passo de rollout (mix task ou manual, decidido no plano):

1. Usuário re-exporta todos os meses do Ourocard em `.txt` e os coloca na pasta
   `Banco/Banco do Brasil - Ourocard/`.
2. Apaga do banco as transações do Ourocard e suas faturas
   (`credit_card_statements` + `transactions` da conta), e apaga os arquivos
   `.ofx` da pasta (autorizado).
3. Troca o `parser_type` da conta para `ourocard_txt`.
4. Reimporta a pasta (`.txt`) — o auto-categorizador roda normalmente — seguido
   de `mix cash_lens.backfill_statements` para popular/vincular as faturas.

Como é reimport do zero, não há casamento de fingerprint entre formatos: sem
risco de duplicata. Ajustes manuais de categoria no histórico do Ourocard são
perdidos (aceito — o auto-categorizador recategoriza).

## Verificação pós-migração

Após reimportar, listar as competências presentes por conta e **apontar meses
faltantes na sequência**, para o usuário conferir se deixou de exportar algum
arquivo. (Check manual do assistente; não é feature persistida.)

## Testes

- `OurocardTXTParser.parse/1`: extrai compras (sinal invertido para negativo),
  créditos/pagamentos (invertidos para positivo), ignora `SALDO ANTERIOR`,
  `SubTotal`, `Total`, cabeçalhos e rótulos; preserva `PARC` na descrição;
  colapsa espaços.
- `extract_statement_meta/1`: `due_date`, `total_a_pagar` e `competencia`
  corretos; degrada a nils se faltar linha.
- `Ingestor.statement_meta/2`: despacha `.txt` para o parser certo.
- Roteamento: `expected_extensions("ourocard_txt")`.
- Fixture: um TXT pequeno representativo (cabeçalho + algumas compras + uma
  linha de pagamento + SALDO ANTERIOR + SubTotal/Total).

## Arquivos

- Criar: `lib/cash_lens/parsers/ourocard_txt_parser.ex`.
- Modificar: `lib/cash_lens/parsers/ingestor.ex` (`parse/2`,
  `expected_extensions/1`, `statement_meta/2`).
- Modificar: `lib/cash_lens/parsers/directory_importer.ex` se o roteamento por
  extensão precisar reconhecer `.txt` para cartão.
- Testes: `test/cash_lens/parsers/ourocard_txt_parser_test.exs`, e casos em
  `ingestor` conforme necessário.
- Migração: passo de rollout (task/manual) — detalhado no plano.
