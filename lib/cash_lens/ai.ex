defmodule CashLens.AI do
  @moduledoc """
  Interface for interacting with Gemini CLI using streaming and secure port execution.
  """

  def research_transaction_stream(description, target_pid) do
    prompt = """
    Pesquise na internet o que significa a transação "#{description}" em um extrato bancário.
    Responda de forma direta e sugira a categoria financeira ideal.
    """

    # Removing --model to use the CLI's default configuration
    path = "/usr/local/bin/gemini"
    args = ["-p", prompt, "--yolo"]

    # We must pass the executable path and use :args for parameters
    Port.open({:spawn_executable, path}, [:binary, :exit_status, args: args])
    |> loop_stream(target_pid)
  end

  defp loop_stream(port, target_pid) do
    receive do
      {^port, {:data, data}} ->
        send(target_pid, {:ai_chunk, data})
        loop_stream(port, target_pid)
      {^port, {:exit_status, 0}} ->
        send(target_pid, :ai_done)
      {^port, {:exit_status, status}} ->
        send(target_pid, {:ai_error, "Erro ao executar IA (Status #{status})."})
    end
  end
end
