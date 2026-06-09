# Saída limpa + barra de progresso na importação por pasta

**Data:** 2026-06-09
**Status:** Aprovado para implementação

## Problema

`mix cash_lens.import <pasta>` hoje polui a saída com os logs `[debug] QUERY OK ...`
do Ecto (e `[info]` da app), porque a task chama `Mix.Task.run("app.start")` e o
nível de log de dev é `:debug`. Além disso, durante uma importação longa (dezenas
de arquivos) não há feedback de progresso — o usuário só vê o relatório no fim.

## Solução

Separar **o que acontece** (o `DirectoryImporter` emite eventos de progresso) de
**como é exibido** (a mix task desenha as barras com a lib `owl`). O
`DirectoryImporter` continua testável e reutilizável pela UI; a apresentação fica
isolada na task.

## Componentes

### 1. Silenciar o ruído (mix task)

No início de `Mix.Tasks.CashLens.Import.run/1`, antes de importar:

- Capturar o nível atual: `previous = Logger.level()`.
- `Logger.configure(level: :warning)` — suprime os `[debug]` (queries Ecto) e
  `[info]`; warnings/errors reais continuam visíveis.
- Ao final (inclusive em caso de erro), restaurar: `Logger.configure(level: previous)`.

Resultado: só as barras + o relatório final ✓/⚠/✗.

### 2. Eventos de progresso (DirectoryImporter)

`run/2` ganha a opção `:on_event` — uma função aridade 1 (default: no-op).
Durante a execução, emite, **na ordem**:

- `{:start, total_accounts}` — número de pastas com `.account` que serão importadas
  (computado antes de começar, varrendo as subpastas / ou 1 se for pasta única).
- `{:account_start, label, file_total}` — `label` = `"Banco / Nome"`; `file_total`
  = número de arquivos com extensão compatível naquela conta.
- `{:file_done, label}` — após cada arquivo daquela conta ser processado.
- `{:account_done, summary}` — `summary` = `%{imported: n, skipped: n, failed: [...]}`.

Pastas puladas (sem `.account`) e erros (conta não encontrada/ambígua, caminho
inválido) **não** emitem eventos de barra — continuam indo só para o `%Result{}`.

**Compatibilidade:** sem `:on_event`, o comportamento é idêntico ao atual. A UI e
os testes existentes não quebram.

### 3. Barras com owl (mix task)

Duas barras ao vivo via `Owl.ProgressBar` + `Owl.LiveScreen`:

- **Geral** (`total` = nº de contas): incrementa a cada `:account_done`.
- **Conta atual** (`total` = nº de arquivos da conta): uma barra nova por conta a
  cada `:account_start` (label = `"Banco / Nome"`), incrementa a cada `:file_done`.

As barras de contas já concluídas permanecem na tela (histórico). Ao final,
`Owl.LiveScreen.await_render()` garante o render final, e então a task imprime o
relatório com `format_lines/1` (✓/⚠/✗), que permanece inalterado.

A task passa para `DirectoryImporter.run/2` uma `:on_event` que traduz cada evento
em chamadas owl (`start`/`inc`).

### 4. Fallback sem TTY

Se a saída não for um terminal interativo (pipe, redirecionamento, CI),
detectado via `IO.ANSI.enabled?/0`, as barras são puladas — a task roda sem
`:on_event` e imprime apenas o relatório texto (`format_lines/1`). Evita lixo de
códigos ANSI em `mix cash_lens.import ... > log.txt`.

### 5. Dependência

Adicionar `{:owl, "~> 0.12"}` ao `mix.exs`. owl não traz dependências transitivas
pesadas (`ucwidth` é opcional). Rodar `mix deps.get`.

## Fluxo de dados

```
run/1 (task)
  ├─ Logger.configure(level: :warning)
  ├─ se ANSI: monta on_event que dirige as barras owl; senão: on_event = nil
  ├─ DirectoryImporter.run(path, on_event: fun)
  │     emite {:start,...} {:account_start,...} {:file_done,...} {:account_done,...}
  ├─ Owl.LiveScreen.await_render() (se ANSI)
  ├─ imprime format_lines(result)
  └─ Logger.configure(level: previous); exit não-zero se result.errors != []
```

## Tratamento de erros

- Restauração do nível de log em `after`/`try` para não vazar o `:warning` se a
  importação levantar.
- Pastas sem `.account`, conta não encontrada/ambígua e caminho inválido seguem
  no `%Result{}` (warnings/errors) e aparecem no relatório final — sem barra.

## Testes

- **DirectoryImporter:** passar um coletor em `:on_event` (ex.: envia para `self()`
  ou acumula numa Agent/lista) e asserir a sequência de eventos para um cenário
  com 2 contas: `{:start, 2}`, depois para cada conta `{:account_start, label, n}`,
  `n`× `{:file_done, label}`, `{:account_done, %{imported: ...}}`. Determinístico.
- Asserir que sem `:on_event` o resultado é idêntico ao atual (nenhum evento, mesmo
  `%Result{}`).
- A fiação do owl e o `Logger.configure` são apresentação/efeito de ambiente →
  verificados manualmente (owl não é unit-testável de forma limpa).
- `format_lines/1` permanece coberto pelos testes existentes.

## Fora de escopo (YAGNI)

- Barras na UI web (a UI já tem seu próprio progresso no modal LiveView).
- Spinner/cores além do padrão do owl (pode ser ajuste posterior).
- Persistir/loggar o progresso em arquivo.
