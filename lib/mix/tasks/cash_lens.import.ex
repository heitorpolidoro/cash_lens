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
