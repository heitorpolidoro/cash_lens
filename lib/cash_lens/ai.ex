defmodule CashLens.AI do
  @moduledoc """
  Interface for interacting with Gemini CLI using streaming and secure port execution.
  """

  require Logger

  def research_transaction_stream(description, target_pid) do
    prompt = """
    Sua tarefa é investigar QUEM pode ser o recebedor desta transação: "#{description}".
    Ignore termos como PIX, TED, Cartão.

    INSTRUÇÕES:
    1. Use `google_web_search` para buscar o nome e listar as possibilidades mais prováveis.
    2. Priorize resultados de São José dos Campos (SJC) e região do Vale do Paraíba.
    3. Apresente os resultados em tópicos (ex: "Possibilidade 1: [Ramo] - [Cidade]").
    4. Se encontrar registros de CNPJ ou perfis profissionais (LinkedIn/Instagram), mencione.
    
    Responda em português, de forma concisa, para que o usuário identifique o gasto.
    """


    path = "/usr/local/bin/gemini"
    args = ["-p", prompt, "--yolo"]
    
    Logger.info("Starting AI Research for: #{description}")

    # We use :exit_status and :stderr_to_stdout to capture everything
    Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout, args: args])
    |> loop_stream(target_pid, description)
  end

  defp loop_stream(port, target_pid, description) do
    receive do
      {^port, {:data, data}} ->
        Logger.debug("AI Chunk received for '#{description}': #{data}")
        send(target_pid, {:ai_chunk, data})
        loop_stream(port, target_pid, description)
      
      {^port, {:exit_status, 0}} ->
        Logger.info("AI Research finished successfully for: #{description}")
        send(target_pid, :ai_done)
      
      {^port, {:exit_status, status}} ->
        Logger.error("AI Research failed with status #{status} for: #{description}")
        send(target_pid, {:ai_error, "A IA encerrou com erro (Status #{status}). Verifique os logs do sistema."})
      
      after 300_000 ->
        # Timeout safety (5 minutes)
        Logger.error("AI Research TIMEOUT for: #{description}")
        Port.close(port)
        send(target_pid, {:ai_error, "A pesquisa demorou demais (5 min) e foi interrompida."})
    end
  end
end
