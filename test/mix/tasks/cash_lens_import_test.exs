defmodule Mix.Tasks.CashLens.ImportTest do
  use ExUnit.Case, async: true
  alias CashLens.Parsers.DirectoryImporter.Result
  alias Mix.Tasks.CashLens.Import

  test "format_lines/1 renders successes, skips, warnings and errors" do
    result = %Result{
      accounts: [
        %{bank: "Banco do Brasil", name: "Conta Corrente", imported: 142, skipped: 8, failed: []},
        %{bank: "Bradesco", name: "Conta Corrente", imported: 67, skipped: 0, failed: []}
      ],
      warnings: ["pasta fatura-antiga/ sem .account — pulada"],
      errors: ["pasta cripto/ — conta 'X' não encontrada"]
    }

    lines = Import.format_lines(result)
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

    text = Import.format_lines(result) |> Enum.join("\n")
    assert text =~ "ruim.csv"
    assert text =~ "parse falhou"
  end
end
