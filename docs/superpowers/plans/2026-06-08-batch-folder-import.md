# Importação em lote por pasta — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permitir importar extratos de várias contas de uma vez apontando para uma pasta-pai, roteando cada subpasta para a conta certa via um arquivo `.account`.

**Architecture:** Lógica em um módulo reutilizável `CashLens.Parsers.DirectoryImporter` (consumível pela UI futura), exposto agora por uma mix task fina `mix cash_lens.import`. Parsing do `.account` isolado em `CashLens.Parsers.AccountFile`. Resolução de conta (case-insensitive, com detecção de ambiguidade) adicionada ao contexto `CashLens.Accounts`. Guarda de extensão em `CashLens.Parsers.Ingestor`.

**Tech Stack:** Elixir, Phoenix, Ecto, ExUnit, Mox (já em uso nos testes do Ingestor).

---

## File Structure

- Create: `lib/cash_lens/parsers/account_file.ex` — parse e leitura do arquivo `.account`.
- Create: `lib/cash_lens/parsers/directory_importer.ex` — orquestra varredura, resolução, guarda de extensão, importação; retorna `%DirectoryImporter.Result{}`.
- Create: `lib/mix/tasks/cash_lens.import.ex` — mix task fina (formatação + exit code).
- Modify: `lib/cash_lens/accounts.ex` — adiciona `find_accounts_by_bank_and_name/2`.
- Modify: `lib/cash_lens/parsers/ingestor.ex` — adiciona `expected_extensions/1`.
- Test: `test/cash_lens/parsers/account_file_test.exs`
- Test: `test/cash_lens/parsers/directory_importer_test.exs`
- Test: `test/cash_lens/accounts_test.exs` (adiciona casos) ou novo describe.
- Test: `test/mix/tasks/cash_lens_import_test.exs`

---

### Task 1: `Accounts.find_accounts_by_bank_and_name/2`

Resolve contas por banco + nome, case-insensitive, retornando **lista** (para o chamador detectar 0 / 1 / ambíguo).

**Files:**
- Modify: `lib/cash_lens/accounts.ex`
- Test: `test/cash_lens/accounts_test.exs`

- [ ] **Step 1: Write the failing test**

Adicione ao final de `test/cash_lens/accounts_test.exs`, dentro do `describe "accounts"` existente (ou crie um novo describe se preferir). Use o fixture `account_fixture/1` (já importado no arquivo via `import CashLens.AccountsFixtures`; se não estiver, adicione o import no topo do módulo de teste).

```elixir
describe "find_accounts_by_bank_and_name/2" do
  test "matches case-insensitively on bank and name" do
    account =
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

    assert [found] = Accounts.find_accounts_by_bank_and_name("banco do brasil", "conta corrente")
    assert found.id == account.id
  end

  test "returns empty list when nothing matches" do
    assert [] = Accounts.find_accounts_by_bank_and_name("Inexistente", "Nada")
  end

  test "returns all matches when ambiguous (same bank + name)" do
    account_fixture(bank: "Banco X", name: "Conta Corrente")
    account_fixture(bank: "Banco X", name: "Conta Corrente")

    assert length(Accounts.find_accounts_by_bank_and_name("Banco X", "Conta Corrente")) == 2
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/accounts_test.exs -o "find_accounts_by_bank_and_name"`
Expected: FAIL com `function CashLens.Accounts.find_accounts_by_bank_and_name/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Em `lib/cash_lens/accounts.ex`, logo após `get_account_by_name/1`, adicione:

```elixir
  @doc """
  Finds accounts matching a bank and name pair, case-insensitively.
  Returns a list so callers can distinguish 0, 1, or ambiguous (2+) matches.
  """
  def find_accounts_by_bank_and_name(bank, name) do
    b = bank |> String.trim() |> String.downcase()
    n = name |> String.trim() |> String.downcase()

    from(a in Account,
      where: fragment("lower(?)", a.bank) == ^b and fragment("lower(?)", a.name) == ^n
    )
    |> Repo.all()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/accounts_test.exs -o "find_accounts_by_bank_and_name"`
Expected: PASS (3 testes).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/accounts.ex test/cash_lens/accounts_test.exs
git commit -m "feat(accounts): find_accounts_by_bank_and_name/2 (case-insensitive)"
```

---

### Task 2: `Ingestor.expected_extensions/1`

Mapeia cada `parser_type` para as extensões de arquivo válidas, usado pela guarda de formato.

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex`
- Test: `test/cash_lens/parsers/ingestor_test.exs`

- [ ] **Step 1: Write the failing test**

Adicione um novo `describe` em `test/cash_lens/parsers/ingestor_test.exs`:

```elixir
describe "expected_extensions/1" do
  test "maps csv parsers to .csv" do
    assert Ingestor.expected_extensions("bradesco_csv") == [".csv"]
    assert Ingestor.expected_extensions("bb_csv") == [".csv"]
  end

  test "maps ofx parsers to .ofx" do
    assert Ingestor.expected_extensions("ourocard_ofx") == [".ofx"]
    assert Ingestor.expected_extensions("standard_ofx") == [".ofx"]
  end

  test "maps pdf parser to .pdf" do
    assert Ingestor.expected_extensions("sem_parar_pdf") == [".pdf"]
  end

  test "returns empty list for unknown parser" do
    assert Ingestor.expected_extensions("unknown") == []
    assert Ingestor.expected_extensions(nil) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs -o "expected_extensions"`
Expected: FAIL com `function CashLens.Parsers.Ingestor.expected_extensions/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Em `lib/cash_lens/parsers/ingestor.ex`, adicione (logo após a função `parse/2`):

```elixir
  @doc """
  Returns the file extensions a given parser_type can handle. Used to guard
  against feeding e.g. an .ofx file to a CSV parser during folder imports.
  """
  def expected_extensions(parser_type) do
    case parser_type do
      t when t in ["bradesco_csv", "bb_csv"] -> [".csv"]
      t when t in ["ourocard_ofx", "standard_ofx"] -> [".ofx"]
      "sem_parar_pdf" -> [".pdf"]
      _ -> []
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs -o "expected_extensions"`
Expected: PASS (4 testes).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/parsers/ingestor.ex test/cash_lens/parsers/ingestor_test.exs
git commit -m "feat(ingestor): expected_extensions/1 for parser format guard"
```

---

### Task 3: `CashLens.Parsers.AccountFile`

Parser do arquivo `.account` (`chave: valor`), e helper de leitura a partir de uma pasta.

**Files:**
- Create: `lib/cash_lens/parsers/account_file.ex`
- Test: `test/cash_lens/parsers/account_file_test.exs`

- [ ] **Step 1: Write the failing test**

Crie `test/cash_lens/parsers/account_file_test.exs`:

```elixir
defmodule CashLens.Parsers.AccountFileTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.AccountFile

  describe "parse/1" do
    test "parses bank and account keys regardless of order" do
      content = "account: Conta Corrente\nbank: Banco do Brasil\n"
      assert {:ok, %{bank: "Banco do Brasil", account: "Conta Corrente"}} = AccountFile.parse(content)
    end

    test "ignores blank lines and comments" do
      content = "# minha conta\n\nbank: Bradesco\n# obs\naccount: Conta Corrente\n"
      assert {:ok, %{bank: "Bradesco", account: "Conta Corrente"}} = AccountFile.parse(content)
    end

    test "trims whitespace around keys and values" do
      content = "  bank :  Banco do Brasil  \n  account :  Ourocard \n"
      assert {:ok, %{bank: "Banco do Brasil", account: "Ourocard"}} = AccountFile.parse(content)
    end

    test "errors when bank is missing" do
      assert {:error, msg} = AccountFile.parse("account: Conta Corrente\n")
      assert msg =~ "bank"
    end

    test "errors when account is missing" do
      assert {:error, msg} = AccountFile.parse("bank: Bradesco\n")
      assert msg =~ "account"
    end

    test "errors when a value is empty" do
      assert {:error, _} = AccountFile.parse("bank:\naccount: X\n")
    end
  end

  describe "read/1 and exists?/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "acctfile_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "exists?/1 reflects presence of .account", %{dir: dir} do
      refute AccountFile.exists?(dir)
      File.write!(Path.join(dir, ".account"), "bank: X\naccount: Y\n")
      assert AccountFile.exists?(dir)
    end

    test "read/1 parses the .account in a directory", %{dir: dir} do
      File.write!(Path.join(dir, ".account"), "bank: Bradesco\naccount: Conta Corrente\n")
      assert {:ok, %{bank: "Bradesco", account: "Conta Corrente"}} = AccountFile.read(dir)
    end

    test "read/1 errors when file is absent", %{dir: dir} do
      assert {:error, _} = AccountFile.read(dir)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/account_file_test.exs`
Expected: FAIL com `module CashLens.Parsers.AccountFile is not available`.

- [ ] **Step 3: Write minimal implementation**

Crie `lib/cash_lens/parsers/account_file.ex`:

```elixir
defmodule CashLens.Parsers.AccountFile do
  @moduledoc """
  Parses `.account` marker files that declare which account a folder belongs to.

  Format (one `key: value` per line; blank lines and `#` comments ignored):

      bank: Banco do Brasil
      account: Conta Corrente
  """

  @filename ".account"

  @doc "The marker filename (`.account`)."
  def filename, do: @filename

  @doc "Whether a `.account` file exists in `dir`."
  def exists?(dir), do: File.exists?(Path.join(dir, @filename))

  @doc "Reads and parses the `.account` file in `dir`."
  def read(dir) do
    path = Path.join(dir, @filename)

    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, "não foi possível ler #{@filename}: #{reason}"}
    end
  end

  @doc "Parses `.account` file content into `%{bank: ..., account: ...}`."
  def parse(content) do
    fields =
      content
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, key |> String.trim() |> String.downcase(), String.trim(value))
          _ -> acc
        end
      end)

    with {:ok, bank} <- fetch(fields, "bank"),
         {:ok, account} <- fetch(fields, "account") do
      {:ok, %{bank: bank, account: account}}
    end
  end

  defp fetch(fields, key) do
    case Map.get(fields, key) do
      nil -> {:error, "#{@filename} sem o campo '#{key}'"}
      "" -> {:error, "#{@filename} com '#{key}' vazio"}
      value -> {:ok, value}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/parsers/account_file_test.exs`
Expected: PASS (todos).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/parsers/account_file.ex test/cash_lens/parsers/account_file_test.exs
git commit -m "feat(parsers): AccountFile parser for .account marker files"
```

---

### Task 4: `DirectoryImporter` — importar UMA pasta de conta

Resolve a conta a partir do `.account`, aplica a guarda de extensão, importa cada arquivo via `Ingestor.import_file/3` e acumula o resultado por conta. (A recursão entra na Task 5.)

**Files:**
- Create: `lib/cash_lens/parsers/directory_importer.ex`
- Test: `test/cash_lens/parsers/directory_importer_test.exs`

- [ ] **Step 1: Write the failing test**

Crie `test/cash_lens/parsers/directory_importer_test.exs`. Usa `DataCase` (precisa de DB) e o fixture de contas. Reaproveita o conteúdo de `test/support/fixtures/files/bb_sample.csv` (3 transações, parser `bb_csv`).

```elixir
defmodule CashLens.Parsers.DirectoryImporterTest do
  use CashLens.DataCase, async: false
  import CashLens.AccountsFixtures

  alias CashLens.Parsers.DirectoryImporter
  alias CashLens.Parsers.DirectoryImporter.Result

  @bb_sample File.read!("test/support/fixtures/files/bb_sample.csv")

  setup do
    root = Path.join(System.tmp_dir!(), "dirimp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp account_folder(root, name, bank, account_name, files) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".account"), "bank: #{bank}\naccount: #{account_name}\n")
    Enum.each(files, fn {fname, content} -> File.write!(Path.join(dir, fname), content) end)
    dir
  end

  describe "run/2 on a single account folder" do
    test "imports matching files into the resolved account", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      dir = account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"extrato.csv", @bb_sample}])

      assert %Result{accounts: [entry], warnings: [], errors: []} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert entry.bank == "Banco do Brasil"
      assert entry.name == "Conta Corrente"
      assert entry.imported == 3
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 3
    end

    test "warns and skips files whose extension does not match the parser", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [
          {"extrato.csv", @bb_sample},
          {"fatura.ofx", "<OFX></OFX>"}
        ])

      assert %Result{accounts: [entry], warnings: [warning]} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert entry.imported == 3
      assert warning =~ "fatura.ofx"
    end

    test "errors (without raising) when account is not found", %{root: root} do
      dir = account_folder(root, "x", "Banco Fantasma", "Conta X", [{"e.csv", @bb_sample}])

      assert %Result{accounts: [], errors: [error]} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert error =~ "não encontrada"
    end

    test "errors when account is ambiguous", %{root: root} do
      account_fixture(bank: "Banco Dup", name: "Conta Corrente", parser_type: "bb_csv")
      account_fixture(bank: "Banco Dup", name: "Conta Corrente", parser_type: "bb_csv")
      dir = account_folder(root, "d", "Banco Dup", "Conta Corrente", [{"e.csv", @bb_sample}])

      assert %Result{errors: [error]} = DirectoryImporter.run(dir, skip_installments: true)
      assert error =~ "ambígua"
    end

    test "re-running imports zero new rows (idempotent via dedupe)", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      dir = account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])

      DirectoryImporter.run(dir, skip_installments: true)
      assert %Result{accounts: [entry]} = DirectoryImporter.run(dir, skip_installments: true)

      assert entry.imported == 0
      assert entry.skipped == 3
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 3
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/directory_importer_test.exs`
Expected: FAIL com `module CashLens.Parsers.DirectoryImporter is not available`.

- [ ] **Step 3: Write minimal implementation**

Crie `lib/cash_lens/parsers/directory_importer.ex`. Nesta task implemente `run/2` apenas para o caso "pasta única de conta" (com `.account` na raiz). A recursão de pasta-pai é adicionada na Task 5.

```elixir
defmodule CashLens.Parsers.DirectoryImporter do
  @moduledoc """
  Imports statement files from a directory, routing each folder to the account
  declared in its `.account` file. Reusable by both the mix task and the web UI.
  """
  alias CashLens.Accounts
  alias CashLens.Parsers.AccountFile
  alias CashLens.Parsers.Ingestor

  defmodule Result do
    @moduledoc "Structured outcome of a directory import."
    defstruct accounts: [], warnings: [], errors: []
  end

  @supported_extensions ~w(.csv .ofx .pdf)

  @doc """
  Imports a directory. Options:
    * `:skip_installments` — when true, does not run installment detection
      (used in tests to keep cases isolated).
  """
  def run(path, opts \\ []) do
    result = import_account_folder(path, %Result{})

    unless Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end

  defp import_account_folder(dir, result) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, account, bank, name, result)
    else
      {:error, reason} ->
        add_error(result, "pasta #{Path.basename(dir)}/ — #{reason}")
    end
  end

  defp resolve_account(bank, name) do
    case Accounts.find_accounts_by_bank_and_name(bank, name) do
      [account] -> {:ok, account}
      [] -> {:error, "conta '#{bank} / #{name}' não encontrada"}
      _ -> {:error, "conta '#{bank} / #{name}' é ambígua"}
    end
  end

  defp do_import(dir, account, bank, name, result) do
    expected = Ingestor.expected_extensions(account.parser_type)
    {matching, mismatched} = partition_files(dir, expected)

    result =
      Enum.reduce(mismatched, result, fn file, acc ->
        add_warning(
          acc,
          "arquivo #{Path.basename(file)} não corresponde ao parser #{account.parser_type} — ignorado"
        )
      end)

    summary =
      Enum.reduce(matching, %{imported: 0, skipped: 0, failed: []}, fn file, acc ->
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
      end)

    entry = Map.merge(summary, %{account: account, bank: bank, name: name})
    %{result | accounts: result.accounts ++ [entry]}
  end

  defp partition_files(dir, expected) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&(Path.extname(&1) |> String.downcase() |> Kernel.in(@supported_extensions)))
    |> Enum.split_with(&(Path.extname(&1) |> String.downcase() |> Kernel.in(expected)))
  end

  defp add_warning(result, msg), do: %{result | warnings: result.warnings ++ [msg]}
  defp add_error(result, msg), do: %{result | errors: result.errors ++ [msg]}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/parsers/directory_importer_test.exs`
Expected: PASS (5 testes).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/parsers/directory_importer.ex test/cash_lens/parsers/directory_importer_test.exs
git commit -m "feat(parsers): DirectoryImporter for single account folder"
```

---

### Task 5: `DirectoryImporter` — varredura recursiva (pasta-pai)

Quando o caminho **não** tem `.account` na raiz, varre as subpastas imediatas: cada subpasta com `.account` é importada; subpasta sem `.account` vira warning.

**Files:**
- Modify: `lib/cash_lens/parsers/directory_importer.ex`
- Test: `test/cash_lens/parsers/directory_importer_test.exs`

- [ ] **Step 1: Write the failing test**

Adicione um novo `describe` ao arquivo de teste (reusa os helpers `account_folder/5` e o setup `:root` já definidos):

```elixir
describe "run/2 on a parent folder" do
  test "imports each subfolder that has an .account", %{root: root} do
    account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
    account_fixture(bank: "Bradesco", name: "Conta Corrente", parser_type: "bb_csv")

    account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])
    account_folder(root, "brad", "Bradesco", "Conta Corrente", [{"e.csv", @bb_sample}])

    assert %Result{accounts: accounts, warnings: [], errors: []} =
             DirectoryImporter.run(root, skip_installments: true)

    assert length(accounts) == 2
    assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 6
  end

  test "warns and skips subfolders without an .account", %{root: root} do
    account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
    account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])

    no_acct = Path.join(root, "fatura-antiga")
    File.mkdir_p!(no_acct)
    File.write!(Path.join(no_acct, "x.csv"), @bb_sample)

    assert %Result{accounts: [_], warnings: [warning]} =
             DirectoryImporter.run(root, skip_installments: true)

    assert warning =~ "fatura-antiga"
    assert warning =~ "sem .account"
  end

  test "one bad subfolder does not abort the others", %{root: root} do
    account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
    account_folder(root, "ok", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])
    account_folder(root, "bad", "Banco Fantasma", "Conta X", [{"e.csv", @bb_sample}])

    assert %Result{accounts: [_], errors: [error]} =
             DirectoryImporter.run(root, skip_installments: true)

    assert error =~ "não encontrada"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/parsers/directory_importer_test.exs -o "parent folder"`
Expected: FAIL — `run/2` ainda chama `AccountFile.read` na raiz (sem `.account`) e devolve só um erro, em vez de varrer subpastas.

- [ ] **Step 3: Write minimal implementation**

Em `lib/cash_lens/parsers/directory_importer.ex`, troque a função `run/2` por uma que decide entre pasta única e pasta-pai, e adicione `import_parent/2`:

```elixir
  def run(path, opts \\ []) do
    result =
      if AccountFile.exists?(path) do
        import_account_folder(path, %Result{})
      else
        import_parent(path, %Result{})
      end

    unless Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end

  defp import_parent(path, result) do
    path
    |> File.ls!()
    |> Enum.map(&Path.join(path, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.reduce(result, fn dir, acc ->
      if AccountFile.exists?(dir) do
        import_account_folder(dir, acc)
      else
        add_warning(acc, "pasta #{Path.basename(dir)}/ sem .account — pulada")
      end
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/parsers/directory_importer_test.exs`
Expected: PASS (todos os describes, single + parent).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/parsers/directory_importer.ex test/cash_lens/parsers/directory_importer_test.exs
git commit -m "feat(parsers): DirectoryImporter recursive parent-folder scan"
```

---

### Task 6: Mix task `mix cash_lens.import`

Casca fina: parseia args, inicia a app, chama `DirectoryImporter.run/1`, formata e imprime o relatório, e sai com código != 0 se houver erros. A formatação é uma função pública pura (`format_lines/1`) para ser testável sem DB.

**Files:**
- Create: `lib/mix/tasks/cash_lens.import.ex`
- Test: `test/mix/tasks/cash_lens_import_test.exs`

- [ ] **Step 1: Write the failing test**

Crie `test/mix/tasks/cash_lens_import_test.exs`. Testa só a formatação pura (a integração com DB/app já está coberta no `DirectoryImporterTest`).

```elixir
defmodule Mix.Tasks.CashLens.ImportTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.DirectoryImporter.Result

  test "format_lines/1 renders successes, skips, warnings and errors" do
    result = %Result{
      accounts: [
        %{bank: "Banco do Brasil", name: "Conta Corrente", imported: 142, skipped: 8, failed: []},
        %{bank: "Bradesco", name: "Conta Corrente", imported: 67, skipped: 0, failed: []}
      ],
      warnings: ["pasta fatura-antiga/ sem .account — pulada"],
      errors: ["pasta cripto/ — conta 'X' não encontrada"]
    }

    lines = Mix.Tasks.CashLens.Import.format_lines(result)
    text = Enum.join(lines, "\n")

    assert text =~ "✓ Banco do Brasil / Conta Corrente"
    assert text =~ "142 importadas"
    assert text =~ "8 já existiam"
    assert text =~ "✓ Bradesco / Conta Corrente"
    assert text =~ "⚠"
    assert text =~ "fatura-antiga"
    assert text =~ "✗"
    assert text =~ "não encontrada"
  end

  test "format_lines/1 renders per-file failures under an account" do
    result = %Result{
      accounts: [
        %{bank: "BB", name: "CC", imported: 0, skipped: 0, failed: [{"ruim.csv", "parse falhou"}]}
      ]
    }

    text = Mix.Tasks.CashLens.Import.format_lines(result) |> Enum.join("\n")
    assert text =~ "ruim.csv"
    assert text =~ "parse falhou"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/cash_lens_import_test.exs`
Expected: FAIL com `module Mix.Tasks.CashLens.Import is not available` ou `function format_lines/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Crie `lib/mix/tasks/cash_lens.import.ex`:

```elixir
defmodule Mix.Tasks.CashLens.Import do
  @shortdoc "Importa extratos de uma pasta, roteando por arquivos .account"
  @moduledoc """
  Importa extratos de uma pasta.

      mix cash_lens.import <caminho>

  Se `<caminho>` contém um arquivo `.account`, é tratado como uma única conta.
  Caso contrário, cada subpasta com `.account` é importada para a conta declarada
  (banco + nome, case-insensitive). Subpastas sem `.account` são puladas com aviso.
  """
  use Mix.Task

  alias CashLens.Parsers.DirectoryImporter

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    result = DirectoryImporter.run(path)

    result
    |> format_lines()
    |> Enum.each(&Mix.shell().info/1)

    if result.errors != [], do: exit({:shutdown, 1})
  end

  def run(_args) do
    Mix.shell().error("Uso: mix cash_lens.import <caminho>")
    exit({:shutdown, 2})
  end

  @doc "Formats a DirectoryImporter.Result into printable lines."
  def format_lines(result) do
    account_lines =
      Enum.flat_map(result.accounts, fn a ->
        extra = if a.skipped > 0, do: ", #{a.skipped} já existiam", else: ""
        header = "✓ #{a.bank} / #{a.name}\t#{a.imported} importadas#{extra}"

        failures =
          Enum.map(a.failed, fn {file, reason} -> "   ✗ #{file}: #{reason}" end)

        [header | failures]
      end)

    warning_lines = Enum.map(result.warnings, &"⚠ #{&1}")
    error_lines = Enum.map(result.errors, &"✗ #{&1}")

    account_lines ++ warning_lines ++ error_lines
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/cash_lens_import_test.exs`
Expected: PASS (2 testes).

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/cash_lens.import.ex test/mix/tasks/cash_lens_import_test.exs
git commit -m "feat(mix): cash_lens.import task over DirectoryImporter"
```

---

### Task 7: Verificação final + documentação curta

**Files:**
- Modify: `README.md` ou `MERIDIAN.md`/docs da pasta (onde estiver a doc de importação; se não houver, adicione uma seção no README).

- [ ] **Step 1: Rodar a suíte inteira**

Run: `mix test`
Expected: tudo verde.

- [ ] **Step 2: Rodar format e credo**

Run: `mix format && mix credo --strict`
Expected: sem ofensas novas.

- [ ] **Step 3: Smoke manual (opcional, fora dos testes)**

Crie uma pasta temporária com `.account` (`bank:`/`account:` de uma conta real) e um CSV, e rode:
Run: `mix cash_lens.import /caminho/da/pasta`
Expected: relatório com `✓ ... N importadas`.

- [ ] **Step 4: Documentar o uso**

Adicione uma seção curta (3-6 linhas) onde a importação é documentada, descrevendo o formato do `.account` e o comando `mix cash_lens.import <pasta>`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(import): document mix cash_lens.import and .account format"
```

---

## Self-Review

**Spec coverage:**
- `.account` formato `chave: valor`, comentários/linhas em branco, campos obrigatórios → Task 3. ✓
- Resolução banco+nome case-insensitive, 0/1/ambíguo → Task 1 (+ uso na Task 4). ✓
- Varredura recursiva (pasta única vs pasta-pai), warning para subpasta sem `.account` → Tasks 4 e 5. ✓
- Guarda de extensão por parser → Tasks 2 e 4. ✓
- Arquivos ficam no lugar (sem mover/apagar) → nenhuma operação de remoção no `DirectoryImporter`; idempotência coberta pelo teste de re-execução na Task 4. ✓
- Detecção de parcelas uma vez ao fim → `run/2` chama `scan_and_apply_all()` (Tasks 4/5); `:skip_installments` só para isolar testes. ✓
- Relatório por conta + warnings + erros, exit code → Task 6. ✓
- Módulo reutilizável pela UI → `DirectoryImporter.run/2` retorna `%Result{}` estruturado. ✓

**Placeholder scan:** sem TBD/TODO; todo passo de código mostra o código completo. ✓

**Type consistency:** `%DirectoryImporter.Result{accounts, warnings, errors}` usado de forma consistente nas Tasks 4–6. Entradas de conta têm chaves `:account, :bank, :name, :imported, :skipped, :failed` em todos os pontos. `find_accounts_by_bank_and_name/2` e `expected_extensions/1` referenciados com a mesma assinatura definida nas Tasks 1 e 2. ✓
