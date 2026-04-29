defmodule CashLens.Parsers.PDFConverter do
  @callback convert(file_path :: String.t()) :: {:ok, String.t()} | {:error, any()}

  defmodule SystemConverter do
    @behaviour CashLens.Parsers.PDFConverter

    @impl true
    def convert(file_path) do
      case System.cmd("pdftotext", ["-layout", file_path, "-"]) do
        {text, 0} -> {:ok, text}
        {_, _code} -> {:error, :failed}
      end
    rescue
      _ -> {:error, :enoent}
    end
  end
end
