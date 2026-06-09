# Saída limpa + barra de progresso na importação — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Limpar a saída de `mix cash_lens.import` (suprimir logs do Ecto) e mostrar barras de progresso estilo rich (geral + conta atual) usando a lib `owl`.

**Architecture:** `DirectoryImporter.run/2` ganha uma opção `:on_event` (callback aridade 1, default no-op) e emite eventos de progresso durante a importação — permanece testável e reutilizável. A mix task silencia o Logger durante a execução e, quando a saída é um TTY, traduz os eventos em barras `owl`; sem TTY cai no relatório texto. owl confirmado: `Owl.ProgressBar.start(id:, label:, total:)`, `Owl.ProgressBar.inc(id:, step:)`, `Owl.LiveScreen.await_render/0`; owl sobe sua `LiveScreen` via `app.start`.

**Tech Stack:** Elixir, Phoenix, ExUnit, owl 0.13.

---

## File Structure

- Modify: `mix.exs` — adiciona `{:owl, "~> 0.13"}`.
- Modify: `lib/cash_lens/parsers/directory_importer.ex` — opção `:on_event` + emissão de eventos; reestrutura `run_existing` para classificar pastas (e conhecer o total) antes de importar.
- Modify: `lib/mix/tasks/cash_lens.import.ex` — silenciar Logger, montar `on_event` que dirige as barras owl quando TTY, fallback texto sem TTY.
- Test: `test/cash_lens/parsers/directory_importer_test.exs` — novo describe para a sequência de eventos.

Os eventos emitidos (contrato, na ordem):
- `{:start, total_accounts}`
- `{:account_start, label, file_total}` — `label` = `"Banco / Nome"`
- `{:file_done, label}` — uma vez por arquivo processado da conta
- `{:account_done, summary}` — `summary` = `%{imported, skipped, failed}`

---

### Task 1: Adicionar dependência `owl`

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Adicionar a dep**

Em `mix.exs`, dentro de `defp deps do [ ... ]`, adicione a linha do owl logo após `{:postgrex, ">= 0.0.0"},`:

```elixir
      {:owl, "~> 0.13"},
```

- [ ] **Step 2: Buscar a dependência**

Run: `mix deps.get`
Expected: saída contém `owl 0.13.x` e `* Getting owl (Hex package)` (ou "already up-to-date" se cacheado).

- [ ] **Step 3: Confirmar que compila e a API existe**

Run: `mix run --no-start -e 'Code.ensure_loaded?(Owl.ProgressBar) and Code.ensure_loaded?(Owl.LiveScreen) |> IO.inspect()'`
Expected: imprime `true`.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build: add owl dependency for CLI progress bars"
```

Antes de commitar rode `mix format --check-formatted` (há hook de pré-commit). `mix.exs` não deve precisar de reformatação, mas confirme.

---

### Task 2: Emitir eventos de progresso no `DirectoryImporter`

Adiciona a opção `:on_event` e emite os eventos do contrato. Reestrutura `run_existing/2` para classificar as pastas (e assim conhecer `total_accounts`) antes de importar. Sem `:on_event`, o comportamento é idêntico ao atual.

**Files:**
- Modify: `lib/cash_lens/parsers/directory_importer.ex`
- Test: `test/cash_lens/parsers/directory_importer_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Acrescente ao final de `test/cash_lens/parsers/directory_importer_test.exs` (antes do `end` final do módulo) um helper privado e um novo describe. O helper `collect_events/0` drena a mailbox do processo de teste preservando a ordem (a importação roda síncrona no mesmo processo sob SQL sandbox).

```elixir
  defp collect_events(acc \\ []) do
    receive do
      {:event, e} -> collect_events([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run/2 progress events" do
    test "emits start, per-account and per-file events in order", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_fixture(bank: "Bradesco", name: "Conta Corrente", parser_type: "bb_csv")

      account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])
      account_folder(root, "brad", "Bradesco", "Conta Corrente", [{"e.csv", @bb_sample}])

      test_pid = self()

      DirectoryImporter.run(root,
        skip_installments: true,
        on_event: &send(test_pid, {:event, &1})
      )

      events = collect_events()

      assert [
               {:start, 2},
               {:account_start, "Banco do Brasil / Conta Corrente", 1},
               {:file_done, "Banco do Brasil / Conta Corrente"},
               {:account_done, %{imported: 3}},
               {:account_start, "Bradesco / Conta Corrente", 1},
               {:file_done, "Bradesco / Conta Corrente"},
               {:account_done, %{imported: 3}}
             ] = events
    end

    test "does not emit account events for unresolved folders", %{root: root} do
      account_folder(root, "bad", "Banco Fantasma", "Conta X", [{"e.csv", @bb_sample}])

      test_pid = self()

      DirectoryImporter.run(root,
        skip_installments: true,
        on_event: &send(test_pid, {:event, &1})
      )

      events = collect_events()

      assert [{:start, 1}] = events
    end

    test "works (and is unchanged) without on_event", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])

      assert %Result{accounts: [entry], warnings: [], errors: []} =
               DirectoryImporter.run(root, skip_installments: true)

      assert entry.imported == 3
    end
  end
```

- [ ] **Step 2: Rodar o teste e ver falhar**

Run: `mix test test/cash_lens/parsers/directory_importer_test.exs -o "progress events"`
Expected: FAIL — nenhum evento chega (`events` vazio), pois `run/2` ainda não emite nem aceita `:on_event`.

- [ ] **Step 3: Implementar**

Em `lib/cash_lens/parsers/directory_importer.ex`, substitua `run_existing/2`, `import_parent/2`, `import_account_folder/2` e `do_import/5` pelo conjunto abaixo. As mudanças: extrai `emit` de `:on_event`; classifica as pastas em (com conta) / (puladas) ANTES de importar para emitir `{:start, n}`; emite `:account_start`, `:file_done`, `:account_done` em `do_import`.

Substitua a função `run_existing/2` inteira:

```elixir
  defp run_existing(path, opts) do
    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    {account_dirs, skipped_dirs} = classify(path)

    emit.({:start, length(account_dirs)})

    result =
      account_dirs
      |> Enum.reduce(%Result{}, fn dir, acc -> import_account_folder(dir, acc, emit) end)
      |> add_skipped_warnings(skipped_dirs)

    unless Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end

  # A path that itself has a `.account` is a single account folder. Otherwise its
  # immediate subdirectories are split into those with a `.account` (to import)
  # and those without (skipped with a warning).
  defp classify(path) do
    if AccountFile.exists?(path) do
      {[path], []}
    else
      path
      |> File.ls!()
      |> Enum.map(&Path.join(path, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort()
      |> Enum.split_with(&AccountFile.exists?/1)
    end
  end

  defp add_skipped_warnings(result, dirs) do
    Enum.reduce(dirs, result, fn dir, acc ->
      add_warning(acc, "pasta #{Path.basename(dir)}/ sem .account — pulada")
    end)
  end
```

Remova a antiga função `import_parent/2` (substituída por `classify/1` + reduce em `run_existing`).

Substitua `import_account_folder/2` por `import_account_folder/3`:

```elixir
  defp import_account_folder(dir, result, emit) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, account, bank, name, result, emit)
    else
      {:error, reason} ->
        add_error(result, "pasta #{Path.basename(dir)}/ — #{reason}")
    end
  end
```

Substitua `do_import/5` por `do_import/6` (emite os eventos de conta/arquivo):

```elixir
  defp do_import(dir, account, bank, name, result, emit) do
    label = "#{bank} / #{name}"
    expected = Ingestor.expected_extensions(account.parser_type)
    {matching, mismatched} = partition_files(dir, expected)

    result =
      Enum.reduce(mismatched, result, fn file, acc ->
        add_warning(
          acc,
          "arquivo #{Path.basename(file)} não corresponde ao parser #{account.parser_type} — ignorado"
        )
      end)

    emit.({:account_start, label, length(matching)})

    summary =
      Enum.reduce(matching, %{imported: 0, skipped: 0, failed: []}, fn file, acc ->
        acc =
          case Ingestor.import_file(account, file) do
            {:ok, s} ->
              %{
                imported: acc.imported + s.imported,
                skipped: acc.skipped + Map.get(s, :skipped, 0),
                failed: acc.failed ++ Map.get(s, :failed, [])
              }

            {:error, reason} ->
              %{acc | failed: acc.failed ++ [{Path.basename(file), reason}]}
          end

        emit.({:file_done, label})
        acc
      end)

    emit.({:account_done, summary})

    entry = Map.merge(summary, %{account: account, bank: bank, name: name})
    %{result | accounts: result.accounts ++ [entry]}
  end
```

Mantenha `run/2`, `resolve_account/2`, `partition_files/2`, `extname/1`, `add_warning/2`, `add_error/2` como estão.

- [ ] **Step 4: Rodar os testes e ver passar**

Run: `mix test test/cash_lens/parsers/directory_importer_test.exs`
Expected: PASS — todos (os 12 existentes + os 3 novos de eventos).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/parsers/directory_importer.ex test/cash_lens/parsers/directory_importer_test.exs
git commit -m "feat(parsers): DirectoryImporter emits progress events via :on_event"
```

Rode `mix format` nos arquivos alterados antes do commit (hook de pré-commit).

---

### Task 3: Silenciar logs + barras owl na mix task

Silencia o Logger durante a importação (restaurando depois), e quando a saída é um TTY traduz os eventos em barras owl (geral + uma barra por conta). Sem TTY, mantém o relatório texto.

**Files:**
- Modify: `lib/mix/tasks/cash_lens.import.ex`

- [ ] **Step 1: Implementar**

Substitua a função `run([path])` (a primeira cláusula de `run/1`) e adicione o helper privado `build_on_event/0`. As demais cláusulas (`run(_args)`) e `format_lines/1` permanecem.

Nova cláusula `run([path])`:

```elixir
  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    previous_level = Logger.level()
    Logger.configure(level: :warning)
    ansi? = IO.ANSI.enabled?()

    try do
      result =
        if ansi? do
          on_event = build_on_event()
          r = DirectoryImporter.run(path, on_event: on_event)
          Owl.LiveScreen.await_render()
          r
        else
          DirectoryImporter.run(path)
        end

      result
      |> format_lines()
      |> Enum.each(&Mix.shell().info/1)

      if result.errors != [], do: exit({:shutdown, 1})
    after
      Logger.configure(level: previous_level)
    end
  end
```

Adicione o helper privado (pode ficar logo após `run(_args)`):

```elixir
  # Builds an :on_event callback that drives two levels of owl progress bars:
  # an overall bar (one tick per account completed) and one bar per account
  # (one tick per file). An Agent holds the per-account bar ids so :file_done
  # can find the right bar by its label.
  defp build_on_event do
    {:ok, agent} = Agent.start_link(fn -> %{n: 0, ids: %{}} end)

    fn
      {:start, total} ->
        Owl.ProgressBar.start(id: :overall, label: "Contas", total: max(total, 1))

      {:account_start, label, file_total} when file_total > 0 ->
        id =
          Agent.get_and_update(agent, fn s ->
            id = :"acc_#{s.n + 1}"
            {id, %{s | n: s.n + 1, ids: Map.put(s.ids, label, id)}}
          end)

        Owl.ProgressBar.start(id: id, label: label, total: file_total)

      {:account_start, _label, _zero} ->
        :ok

      {:file_done, label} ->
        case Agent.get(agent, &Map.get(&1.ids, label)) do
          nil -> :ok
          id -> Owl.ProgressBar.inc(id: id)
        end

      {:account_done, _summary} ->
        Owl.ProgressBar.inc(id: :overall)
    end
  end
```

Garanta que `Owl` está referenciado (não precisa de `alias`; use `Owl.ProgressBar` / `Owl.LiveScreen` totalmente qualificados como acima).

- [ ] **Step 2: Compilar sem warnings**

Run: `mix compile --warnings-as-errors`
Expected: compila sem warnings.

- [ ] **Step 3: Verificar que os testes existentes seguem verdes**

Run: `mix test test/mix/tasks/cash_lens_import_test.exs`
Expected: PASS (os testes de `format_lines/1` não foram afetados).

- [ ] **Step 4: Smoke manual — saída limpa, sem barra (sem TTY / pipe)**

Cria uma pasta-pai com uma subpasta sem `.account` e roda com a saída em pipe (ANSI desabilitado):

Run:
```bash
tmp=$(mktemp -d) && mkdir -p "$tmp/sem_marca" && touch "$tmp/sem_marca/x.csv" && mix cash_lens.import "$tmp" 2>&1 | cat; rm -rf "$tmp"
```
Expected: NENHUMA linha `[debug] QUERY ...`; apenas `⚠ pasta sem_marca/ sem .account — pulada`. Exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/cash_lens.import.ex
git commit -m "feat(mix): silence logs and show owl progress bars in cash_lens.import"
```

Rode `mix format` antes do commit.

---

### Task 4: Verificação final + doc

**Files:**
- Modify: `README.md` (seção de importação já existente).

- [ ] **Step 1: Suíte completa**

Run: `mix test`
Expected: tudo verde.

- [ ] **Step 2: Format + credo**

Run: `mix format && mix credo --strict`
Expected: sem ofensas novas.

- [ ] **Step 3: Smoke com TTY (opcional, manual)**

Num terminal interativo, com uma pasta de conta real marcada com `.account`, rode `mix cash_lens.import <pasta>` e confirme: barras owl aparecem (geral + por conta), sem logs de SQL, e o relatório ✓/⚠/✗ ao final.

- [ ] **Step 4: Documentar**

No `README.md`, na seção "Importing statements from folders", acrescente uma linha após a lista existente:

```markdown
- Output is clean (Ecto query logs are suppressed during import); in an interactive
  terminal a progress bar is shown per account plus an overall bar.
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(import): note clean output and progress bars"
```

---

## Self-Review

**Spec coverage:**
- Silenciar ruído (Logger :warning + restore) → Task 3 (`run/1` com try/after). ✓
- Eventos `:on_event` (`:start`/`:account_start`/`:file_done`/`:account_done`) → Task 2. ✓
- Compatibilidade sem `:on_event` (default no-op, idêntico ao atual) → Task 2 (default `fn _ -> :ok end`; teste "works without on_event"). ✓
- Duas barras owl (geral + conta atual, barras concluídas permanecem) → Task 3 (`:overall` + `:"acc_#{n}"` por conta). ✓
- Fallback sem TTY (`IO.ANSI.enabled?`) → Task 3. ✓
- Dependência owl → Task 1. ✓
- Testes nos eventos; format_lines mantido → Task 2 (+ Task 3 step 3). ✓

**Placeholder scan:** sem TBD/TODO; todo passo de código mostra o código completo. ✓

**Type consistency:** eventos `{:start, n}`, `{:account_start, label, file_total}`, `{:file_done, label}`, `{:account_done, summary}` idênticos entre emissor (Task 2 `do_import/6` e `run_existing/2`) e consumidor (Task 3 `build_on_event/0`). `label` = `"#{bank} / #{name}"` consistente. owl: `start(id:, label:, total:)` / `inc(id:)` / `LiveScreen.await_render/0` conferem com a API verificada. ✓
