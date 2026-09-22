defmodule CashLens.Parsers.MercadoPagoPDFParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Parser for the Mercado Pago **checking account** PDF statement (`EXTRATO DE
  CONTA`), reading the text `CashLens.Parsers.PDFConverter` extracts with
  `pdftotext -layout`.

  Distinct from the Mercado Pago card invoice, which `CashLens.Parsers.PDFParser`
  handles as `:mercado_pago_card`: that document is line-shaped, this one is a
  `Data | Descrição | ID da operação | Valor | Saldo` table whose description is
  vertically centred around the transaction line, occupying up to two lines above
  and two below it.

  ## Algorithm

  1. **Strip noise positionally**, never by content match. Everything above the
     `DETALHE DOS MOVIMENTOS` marker (title, identity line, `CPF/CNPJ … Conta:`,
     `Periodo:`, `Saldo inicial/final`, `Entradas`, `Saidas`) and everything from
     the `Data de geração:` line onward (SAC/ouvidoria and legal boilerplate) is
     dropped, plus standalone `N/M` page markers and the column-header line
     wherever they occur. Content matching would be unsafe: the account holder's
     name is both the identity header and part of a real description
     (`Pix enviado Heitor Luis` / `Polidoro`), so a rule keyed on that string
     would eat a description.

     The form feed is treated as **whitespace inside its line, never as a line
     of its own** — the bank glues it to a transaction line
     (`"\\f   14-11-2025  Rendimentos  …"`), so discarding lines that contain it
     deletes that transaction outright. It survives segmentation so that
     `transaction_blocks/1` can still report which line opens a page.

  2. **Segment** the surviving lines into blocks on runs of blank lines.

  3. Each block holds **exactly one** transaction line; its other lines are that
     transaction's description, read top to bottom, with the transaction line's
     own inline fragment inserted in position (above → inline → below).

  A block with zero transaction lines, or with more than one, raises. Because
  noise is removed positionally, stripped lines never enter a block, so a
  surviving zero-transaction block is unrecognised content rather than noise and
  is never dropped silently.

  The statement never splits a table row across a page break, so there is no
  cross-page merge rule. The operation id is read only to locate the amount
  columns and is **not** part of the return value: it is not unique per
  transaction (a purchase and its refund share an order id) and must never become
  a deduplication key.
  """

  @movements_marker "DETALHE DOS MOVIMENTOS"
  @footer_marker "Data de geração:"
  @column_header_marker "ID da operação"

  @page_marker_regex ~r{^\d+/\d+$}

  # date · inline description fragment · operation id · Valor · Saldo
  @transaction_regex ~r/^\s*(\d{2})-(\d{2})-(\d{4})\s+(.*?)\s*(\d{10,})\s+R\$\s*(-?[\d.]+,\d{2})\s+R\$\s*-?[\d.]+,\d{2}\s*$/u

  @impl true
  def parse(content, _format \\ :mercado_pago_conta) do
    content
    |> transaction_blocks()
    |> Enum.map(&parse_block/1)
  end

  @doc """
  The statement's blocks after positional noise stripping, each a list of raw
  lines with the form feed still in place.

  Exposed so the opt-in corpus test can assert structural properties of the real
  statements — the shape distribution, and that no block spans a page break (a
  block that did would carry a form-feed line somewhere other than its first
  line). `parse/2` is the only consumer in production code.
  """
  @spec transaction_blocks(String.t()) :: [[String.t()]]
  def transaction_blocks(content) do
    content
    |> strip_noise()
    |> blocks()
  end

  # --- Positional noise stripping ---

  defp strip_noise(content) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.drop_while(&(not String.contains?(&1, @movements_marker)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), @footer_marker)))
    |> Enum.reject(&noise_line?/1)
  end

  defp noise_line?(line) do
    trimmed = String.trim(line)

    String.contains?(trimmed, @column_header_marker) or
      Regex.match?(@page_marker_regex, trimmed)
  end

  # --- Segmentation ---

  defp blocks(lines) do
    lines
    |> Enum.chunk_by(&blank?/1)
    |> Enum.reject(fn chunk -> Enum.all?(chunk, &blank?/1) end)
  end

  defp blank?(line), do: String.trim(line) == ""

  # --- Block to transaction ---

  defp parse_block(block) do
    case transaction_indexes(block) do
      [index] ->
        {above, [transaction_line | below]} = Enum.split(block, index)
        build(transaction_line, above, below)

      [] ->
        raise "MercadoPagoPDFParser: block with no transaction line:\n#{Enum.join(block, "\n")}"

      _many ->
        raise "MercadoPagoPDFParser: block with more than one transaction line:\n" <>
                Enum.join(block, "\n")
    end
  end

  defp transaction_indexes(block) do
    block
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} -> transaction_line?(line) end)
    |> Enum.map(fn {_line, index} -> index end)
  end

  defp transaction_line?(line), do: Regex.match?(@transaction_regex, line)

  # The description is read top to bottom, with the transaction line's own inline
  # fragment inserted in position: above → inline → below.
  defp build(transaction_line, above, below) do
    [_, day, month, year, inline, _id, value] = Regex.run(@transaction_regex, transaction_line)

    %{
      date: to_date(year, month, day),
      time: nil,
      description: join_description(above ++ [inline] ++ below),
      amount: to_amount(value)
    }
  end

  defp join_description(parts) do
    parts
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp to_date(year, month, day) do
    Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day))
  end

  # "R$ -1.099,00" arrives here as "-1.099,00": the sign sits after the R$, "." is
  # the thousands separator and "," the decimal separator.
  defp to_amount(value) do
    value
    |> String.replace(".", "")
    |> String.replace(",", ".")
    |> Decimal.new()
  end
end
