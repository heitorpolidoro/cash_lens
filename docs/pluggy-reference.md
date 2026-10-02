# Pluggy (Open Finance) — referência da integração removida

A integração com a **Pluggy** foi removida do Cash Lens em **02/10/2026**. Este
documento existe para que ela possa ser reconstruída sem arqueologia: o que
fazia, onde tocava, por que saiu, e o que já se sabia que estava errado.

> **O jeito mais rápido de trazê-la de volta é reverter o commit de remoção**
> (`git log --grep "remove the Pluggy"`). Tudo abaixo descreve o estado
> anterior a ele.

---

## Por que foi removida

O gatilho foi um número errado na tela. A dashboard mostrava **Saldo Atual de
R$ 27.491,64** enquanto a soma real das contas era **R$ 20.433,33**. A diferença
vinha de um `pluggy_balance` desatualizado da conta BB Rende Fácil — 26.203,47
contra os 19.229,80 corretos, que o operador tinha acabado de corrigir à mão.

Dois defeitos estruturais ficaram claros nesse episódio:

1. **O `pluggy_balance` sobrepunha o saldo calculado**, inclusive um corrigido
   manualmente. O operador corrigia o saldo e a tela continuava mostrando o
   valor antigo, sem indicar de onde ele vinha.
2. **O saldo do Pluggy entrava no "Saldo Atual" mas não em "Receitas"/"Despesas"**,
   e o card "Balanço" era calculado como `Saldo Atual − saldos de abertura`.
   Resultado: "Balanço" deixava de ser igual a receitas menos despesas, sem que
   nada na tela explicasse a diferença. Depois da remoção os três voltaram a
   fechar: 410,69 − 0,35 = 410,34.

Havia ainda sinais de dado ruim não investigados: o **Ourocard** tinha
`pluggy_balance` de **+22.362,00** para um cartão cujo saldo calculado era
−2.757,50 — sinal aparentemente invertido.

---

## O que a integração fazia

Três capacidades distintas, que convém não confundir ao reconstruir:

### 1. Saldos reportados pelo banco (`pluggy_balance`)

Sincronizados sob demanda e **guardados no banco**, em `pluggy_account_links`.
A dashboard preferia esse valor ao saldo calculado, com a justificativa de que o
número do banco é mais confiável que "saldo persistido + delta estimado" — o
caso concreto citado no código era um PIX presente no extrato do banco e ausente
da API de transações da Pluggy.

**Era essa preferência que causava o defeito 1.** Se voltar, ela precisa de uma
regra de obsolescência (quando o `pluggy_balance` é velho demais para valer) e
de indicação visual de qual número está sendo mostrado.

### 2. Pré-visualização ao vivo (live preview)

Transações ainda não importadas, buscadas na API e mantidas **apenas em memória**,
num `GenServer` de cache. Nunca eram persistidas. Apareciam em `/transactions`
como linhas temporárias, com fundo amarelo e selo "Temporário", e somavam na
faixa de resumo.

Estava **desligada por configuração** (`:pluggy_live_preview_enabled, false`)
desde antes da remoção, mas o código continuava vivo e o cache continuava sendo
lido pela dashboard.

### 3. Categoria sugerida pela Pluggy

`transactions.pluggy_category`, exibida como um selo discreto na linha. Na
remoção, **nenhuma transação tinha esse campo preenchido** (0 linhas).

---

## Onde tocava

### Módulos dedicados (todos removidos)

| Caminho | Papel |
|---|---|
| `lib/cash_lens/pluggy.ex` | Contexto: itens e vínculos de conta |
| `lib/cash_lens/pluggy/client.ex` | Cliente HTTP da API (via `Req`) |
| `lib/cash_lens/pluggy/item.ex` | Schema `pluggy_items` |
| `lib/cash_lens/pluggy/account_link.ex` | Schema `pluggy_account_links` |
| `lib/cash_lens/pluggy/live_preview.ex` | Regras da pré-visualização |
| `lib/cash_lens/pluggy/live_preview/entry.ex` | Struct da linha temporária |
| `lib/cash_lens/pluggy/live_preview_cache.ex` | `GenServer` do cache em memória |
| `lib/cash_lens/transactions/pluggy_matcher.ex` | Casava categoria da Pluggy nas linhas |
| `lib/cash_lens_web/live/pluggy_live/index.ex` | Tela `/pluggy` |

Testes e fixtures correspondentes, incluindo `test/support/fake_live_preview_cache.ex`.

### Pontos de integração (todos limpos)

- `lib/cash_lens/application.ex` — o cache entrava na árvore de supervisão.
- `lib/cash_lens_web/router.ex` — rota `live "/pluggy"`.
- `lib/cash_lens_web/components/layouts.ex` — item de menu "Conexões Bancárias".
- `lib/cash_lens_web/live/account_live/index.ex` — botão para `/pluggy`.
- `lib/cash_lens_web/controllers/page_controller.ex` — a sobreposição de saldo e
  a soma das entradas ao vivo.
- `lib/cash_lens_web/live/transaction_live/index.ex` e seu template — o evento
  `sync_pluggy`, o banner de erro, as linhas temporárias, o selo de categoria e
  toda a filtragem das entradas ao vivo (era a maior concentração, ~54 pontos).
- `lib/cash_lens/transactions/transaction.ex` — campo `pluggy_category` e o
  valor `"pluggy"` em `validate_inclusion(:source, …)`.

### Esquema de dados

Removidos pela migração `20261002150000_drop_pluggy.exs`, que tem `down/0`
completo — rodar `mix ecto.rollback` recria as duas tabelas e a coluna.

- tabela `pluggy_items` (3 linhas na remoção)
- tabela `pluggy_account_links` (8 linhas)
- coluna `transactions.pluggy_category` (0 preenchidas)

**`transactions.source` foi mantida de propósito.** Ela chegou junto com o
trabalho da Pluggy, mas distingue `"file"` de `"manual"` e é lida em todo o app.
Só o valor `"pluggy"` deixou de ser aceito, e nenhuma linha o usava.

### Configuração

```elixir
# config/config.exs
config :cash_lens, :pluggy_live_preview_enabled, false

# config/test.exs
config :cash_lens, :pluggy_req_options, plug: {Req.Test, CashLens.Pluggy.Client}
```

Credenciais vinham do ambiente: `PLUGGY_CLIENT_ID` e `PLUGGY_CLIENT_SECRET`.

**Não havia dependência dedicada no `mix.exs`** — o cliente usava o `Req`, que
continua no projeto por outros motivos. Nada a reinstalar.

---

## O que foi preservado

| Arquivo | Conteúdo |
|---|---|
| `docs/pluggy/pluggy-data-snapshot.sql` | As 11 linhas das duas tabelas, com `INSERT`s, mais o schema |
| `docs/pluggy/live-preview-uncommitted.patch` | Alterações **não commitadas** em `live_preview.ex` e seu teste, que existiam na árvore no momento da remoção e teriam se perdido |

O patch merece atenção se a integração voltar: eram 46 inserções e 33 remoções
de trabalho em andamento, nunca commitado, cujo propósito não está registrado em
lugar nenhum.

---

## Se for reconstruir

Na ordem em que os problemas apareceriam:

1. **Reverta o commit de remoção** em vez de reescrever. Ele contém tudo.
2. **Decida o que fazer com `pluggy_balance` antes de religar a dashboard.**
   O defeito que motivou a remoção foi um saldo da API sobrepor silenciosamente
   um valor corrigido à mão. Opções: tratar o número da API como sugestão e não
   como verdade; expirá-lo por idade; ou exibir os dois lado a lado com a
   origem explícita.
3. **Investigue o sinal do saldo de cartão.** O Ourocard vinha positivo onde o
   cálculo dava negativo. Não foi apurado.
4. **Reavalie o card "Balanço" da dashboard.** Ele é `Saldo Atual − saldos de
   abertura`, não receitas menos despesas, e o rótulo "Resultado líquido do mês"
   promete a segunda coisa. Com dados ao vivo entrando só num dos lados, a
   diferença volta a aparecer.
5. **A pré-visualização ao vivo já estava desligada** quando a remoção
   aconteceu. Confirme que ela ainda é desejada antes de reconstruir a parte
   mais complexa do conjunto.
