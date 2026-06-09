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

  require Logger

  alias CashLens.Parsers.DirectoryImporter

  @impl Mix.Task
  def run([path]) do
    Application.put_env(:cash_lens, :start_console_reporter, false)
    Mix.Task.run("app.start")

    previous_level = Logger.level()
    Logger.configure(level: :warning)
    ansi? = IO.ANSI.enabled?()

    try do
      {result, agent} =
        if ansi? do
          {on_event, agent} = build_on_event()
          result = DirectoryImporter.run(path, on_event: on_event)
          Owl.LiveScreen.await_render()
          {result, agent}
        else
          {DirectoryImporter.run(path), nil}
        end

      result
      |> format_lines()
      |> Enum.each(&Mix.shell().info/1)

      if agent, do: Agent.stop(agent)

      if result.errors != [], do: exit({:shutdown, 1})
    after
      Logger.configure(level: previous_level)
    end
  end

  def run(_args) do
    Mix.shell().error("Uso: mix cash_lens.import <caminho>")
    exit({:shutdown, 2})
  end

  # Builds an :on_event callback that drives two levels of owl progress bars:
  # an overall bar (one tick per account completed) and one bar per account
  # (one tick per file). An Agent holds the per-account bar ids so :file_done
  # can find the right bar by its label.
  defp build_on_event do
    {:ok, agent} = Agent.start_link(fn -> %{n: 0, ids: %{}} end)

    handler = fn
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

    {handler, agent}
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
