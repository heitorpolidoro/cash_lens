defmodule CashLens.Parsers.FormatDetector do
  @moduledoc """
  Content-based detection of a statement file's format, parser and owning account.

  Answers the one question no other module answers today — "no account is known,
  which parser reads these bytes?" — and answers it in the existing vocabulary,
  returning one of `CashLens.Parsers.AccountFile.valid_parsers/0` so the caller can
  hand it straight to `CashLens.Parsers.Ingestor.parse/2`.

  This module is **pure**: it touches neither the Repo, nor the filesystem, nor
  `PDFConverter`/`System`. PDF text must be extracted by the caller and passed in
  through the `:text` option.

  ## Detection order (total, first match wins)

  1. **PDF text** — `opts[:text]` is a binary that is not blank after trimming.
     The `%PDF-` magic is *not* required on `content` here, because callers pass
     `pdftotext` output whose `content` may be the original PDF or the text itself.
     Always yields `format: :pdf`.
  2. **Raw PDF** — `content` starts with the `%PDF-` magic and no `:text` was given.
     The text lives in compressed streams, so nothing further is inferable:
     `parser_type: nil`, `account_hint: nil`.
  3. **OFX** — `OFXHEADER` (1.x SGML) or an `<OFX>` / `<?OFX` root (2.x XML).
  4. **Ourocard TXT** — `H_VENC or L_TX` (see below).
  5. **CSV** — the C1/C2/C3 header probes below.
  6. Otherwise `{:error, :unrecognized}`.

  OFX precedes the text formats because an SGML/XML OFX body can contain commas and
  semicolons a naive CSV probe would accept; Ourocard TXT precedes CSV for the same
  reason.

  ### PDF-text probes (total order P1 → P2 → P3)

  The order between these three is itself normative, because their markers overlap
  in real documents.

  * **P1 — `"sem_parar_pdf"`**: text contains `Plano Contratado`.
  * **P2 — `"mercadopago_cartao_pdf"`**: text contains `Total a pagar` or
    `Movimentações na fatura`.
  * **P3 — `"bradesco_cartao_pdf"`**: text contains `Total da fatura` or
    `Bradesco Cartões`.

  P3's markers also appear in real Mercado Pago faturas, which carry
  `Total da fatura de <mês>` (the same collision `PDFParser` documents when it
  routes total extraction by `Total a pagar`). P3 is therefore reachable only after
  P2 has been evaluated and failed — that ordering, not the marker itself, is what
  keeps a Mercado Pago fatura out of the Bradesco bucket.

  ### Ourocard TXT probe

  * `H_VENC` — content matches `Vencimento : DD.MM.YYYY`.
  * `L_TX` — at least one line has the leading `DD.MM.YYYY` transaction shape.

  The predicate is `H_VENC or L_TX`. A `Total da fatura : R$` line is neither
  necessary nor sufficient and is deliberately not part of the predicate.

  ### CSV probes (total order C1 → C2 → C3)

  Rows are `content` split on newlines, with a leading UTF-8 BOM stripped from the
  first row. A row's fields are the row split on `";"` when it contains a `;`, else
  on `","`.

  * **C1 — `"mercado_pago_csv"`**: any row (not only the first) whose first trimmed
    field is exactly `RELEASE_DATE`.
  * **C2 — `"bradesco_csv"`**: any row whose trimmed fields begin with the verbatim
    Bradesco header.
  * **C3 — `"bb_csv"`**: the first non-blank row, normalised the way
    `CSVParser.normalize_header/1` normalises, has a field containing `data`, one
    containing `valor`, and one containing `hist` or `lancamento`.

  No CSV probe matching is `{:error, :unrecognized}`: the detector never falls back
  to "some CSV parser" and guesses.

  ## Account hints

  `account_hint` is advisory — a hint for matching an existing `Account`, never an
  assertion, and never an identification of a specific local account. Any field
  content alone cannot establish is `nil`.
  """

  alias CashLens.Parsers.AccountFile

  @type format :: :ofx | :csv | :pdf | :txt

  @type account_hint :: %{
          bank: String.t() | nil,
          credit_card: boolean() | nil,
          account_identifier: String.t() | nil
        }

  @type verdict :: %{
          format: format(),
          parser_type: String.t() | nil,
          account_hint: account_hint() | nil
        }

  @type option :: {:filename, String.t() | nil} | {:text, String.t() | nil}

  @pdf_magic "%PDF-"

  @ofx_header_regex ~r/OFXHEADER/i
  @ofx_root_regex ~r/<\?OFX|<OFX[>\s]/i
  @ofx_credit_card_regex ~r/<CCSTMTTRN>/i
  @ofx_org_regex ~r/<ORG>([^<\r\n]*)/i
  @ofx_acctid_regex ~r/<ACCTID>([^<\r\n]*)/i

  # Exact regex of OurocardTXTParser.extract_due_date/1.
  @ourocard_due_date_regex ~r/Vencimento\s*:\s*\d{2}\.\d{2}\.\d{4}/i
  # Mirrors OurocardTXTParser's @line_regex (the leading DD.MM.YYYY transaction shape).
  @ourocard_line_regex ~r/^(\d{2})\.(\d{2})\.(\d{4})(.+?)\s+(-?[\d.]+,\d{2})\s+-?[\d.]+,\d{2}\s*$/

  @bradesco_csv_header [
    "Data",
    "Histórico",
    "Docto.",
    "Crédito (R$)",
    "Débito (R$)",
    "Saldo (R$)"
  ]

  @bom "﻿"

  @detectable_parsers ~w(
    bb_csv bradesco_csv mercado_pago_csv standard_ofx ourocard_txt
    sem_parar_pdf bradesco_cartao_pdf mercadopago_cartao_pdf
  )

  # Compile-time guarantee that the vocabulary above is a subset of the one the
  # rest of the ingestion pipeline accepts, so the two lists cannot drift apart.
  @unknown_parsers Enum.reject(@detectable_parsers, &(&1 in AccountFile.valid_parsers()))

  if @unknown_parsers != [] do
    raise "FormatDetector would return parser types unknown to AccountFile: #{inspect(@unknown_parsers)}"
  end

  @doc """
  Detects the format, parser and account hint of `content`.

  Options:

    * `:filename` — advisory only. It never participates in the decision; a file
      whose extension contradicts its content is classified by its content.
    * `:text` — PDF text already extracted by the caller (the detector must not
      shell out to `pdftotext` itself).

  Returns `{:ok, %{format: format, parser_type: parser_type, account_hint: hint}}`,
  or `{:error, :unrecognized}` for empty content, for content matching no signature,
  and for content whose format is recognised but whose bytes carry no usable
  discriminator. Never raises, including on binary garbage and invalid UTF-8.
  """
  @spec detect(term(), [option()]) :: {:ok, verdict()} | {:error, :unrecognized}
  def detect(content, opts \\ [])

  def detect(content, opts) when is_binary(content) and is_list(opts) do
    text = opts |> Keyword.get(:text) |> printable()

    cond do
      not blank?(text) -> {:ok, pdf_text_verdict(text)}
      String.starts_with?(content, @pdf_magic) -> {:ok, raw_pdf_verdict()}
      true -> detect_text_format(printable(content))
    end
  end

  def detect(_content, _opts), do: {:error, :unrecognized}

  defp detect_text_format(content) do
    cond do
      ofx?(content) -> {:ok, ofx_verdict(content)}
      ourocard_txt?(content) -> {:ok, ourocard_verdict()}
      true -> csv_verdict(content)
    end
  end

  # --- PDF ---

  defp raw_pdf_verdict, do: %{format: :pdf, parser_type: nil, account_hint: nil}

  defp pdf_text_verdict(text) do
    case pdf_text_parser(text) do
      nil -> %{format: :pdf, parser_type: nil, account_hint: nil}
      {parser_type, bank, credit_card} -> verdict(:pdf, parser_type, bank, credit_card)
    end
  end

  # P1 → P2 → P3. The order is normative: see the moduledoc.
  defp pdf_text_parser(text) do
    cond do
      String.contains?(text, "Plano Contratado") ->
        {"sem_parar_pdf", "Sem Parar", false}

      String.contains?(text, ["Total a pagar", "Movimentações na fatura"]) ->
        {"mercadopago_cartao_pdf", "Mercado Pago", true}

      String.contains?(text, ["Total da fatura", "Bradesco Cartões"]) ->
        {"bradesco_cartao_pdf", "Bradesco", true}

      true ->
        nil
    end
  end

  # --- OFX ---

  defp ofx?(content) do
    Regex.match?(@ofx_header_regex, content) or Regex.match?(@ofx_root_regex, content)
  end

  # parser_type is always "standard_ofx": no sample carries a grounded
  # discriminator for "ourocard_ofx", and both types dispatch to OFXParser, whose
  # format argument is ignored. Any Banco do Brasil belief lives in the hint only.
  defp ofx_verdict(content) do
    %{
      format: :ofx,
      parser_type: "standard_ofx",
      account_hint: %{
        bank: tag_value(content, @ofx_org_regex),
        credit_card: Regex.match?(@ofx_credit_card_regex, content),
        account_identifier: tag_value(content, @ofx_acctid_regex)
      }
    }
  end

  defp tag_value(content, regex) do
    case Regex.run(regex, content) do
      [_, value] -> value |> String.trim() |> presence()
      _ -> nil
    end
  end

  # --- Ourocard TXT ---

  defp ourocard_txt?(content) do
    Regex.match?(@ourocard_due_date_regex, content) or
      Enum.any?(lines(content), &Regex.match?(@ourocard_line_regex, &1))
  end

  defp ourocard_verdict, do: verdict(:txt, "ourocard_txt", "Banco do Brasil", true)

  # --- CSV ---

  defp csv_verdict(content) do
    rows = content |> lines() |> strip_bom() |> Enum.map(&fields/1)

    case csv_parser(rows) do
      nil -> {:error, :unrecognized}
      {parser_type, bank} -> {:ok, verdict(:csv, parser_type, bank, false)}
    end
  end

  # C1 → C2 → C3.
  defp csv_parser(rows) do
    cond do
      Enum.any?(rows, &mercado_pago_row?/1) -> {"mercado_pago_csv", "Mercado Pago"}
      Enum.any?(rows, &bradesco_row?/1) -> {"bradesco_csv", "Bradesco"}
      bb_header?(first_non_blank_row(rows)) -> {"bb_csv", "Banco do Brasil"}
      true -> nil
    end
  end

  # Matches CSVParser.mercado_pago_header_row?/1, which CSVParser reaches with
  # Enum.drop_while — so the header need not be the first row.
  defp mercado_pago_row?([first | _]), do: String.trim(first) == "RELEASE_DATE"
  defp mercado_pago_row?(_), do: false

  defp bradesco_row?(fields) do
    fields
    |> Enum.map(&String.trim/1)
    |> Enum.take(length(@bradesco_csv_header)) == @bradesco_csv_header
  end

  # The needles are exactly the ones CSVParser.bb_column_mapping/1 looks up, so
  # both documented BB export layouts (Histórico, and Lançamento/Detalhes) pass.
  defp bb_header?(nil), do: false

  defp bb_header?(fields) do
    normalized = Enum.map(fields, &normalize_header/1)

    contains_needle?(normalized, "data") and contains_needle?(normalized, "valor") and
      (contains_needle?(normalized, "hist") or contains_needle?(normalized, "lancamento"))
  end

  defp contains_needle?(normalized, needle),
    do: Enum.any?(normalized, &String.contains?(&1, needle))

  # Same normalisation as CSVParser.normalize_header/1.
  defp normalize_header(field) do
    field
    |> String.trim()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end

  defp first_non_blank_row(rows), do: Enum.find(rows, &(not blank_row?(&1)))

  defp blank_row?(fields), do: Enum.all?(fields, &(String.trim(&1) == ""))

  defp fields(row) do
    if String.contains?(row, ";"), do: String.split(row, ";"), else: String.split(row, ",")
  end

  defp strip_bom([first | rest]), do: [String.replace_prefix(first, @bom, "") | rest]
  defp strip_bom([]), do: []

  # --- Shared helpers ---

  defp verdict(format, parser_type, bank, credit_card) do
    %{
      format: format,
      parser_type: parser_type,
      account_hint: %{bank: bank, credit_card: credit_card, account_identifier: nil}
    }
  end

  defp lines(content), do: String.split(content, ~r/\r?\n/)

  defp blank?(nil), do: true
  defp blank?(binary), do: String.trim(binary) == ""

  defp presence(""), do: nil
  defp presence(value), do: value

  # Statement files are not guaranteed to be UTF-8 (latin-1 exports are common), and
  # String/Regex operations on invalid UTF-8 would be unreliable, so undecodable
  # bytes are reinterpreted as latin-1 — the same tolerance Ingestor applies.
  defp printable(nil), do: nil

  defp printable(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      case :unicode.characters_to_binary(binary, :latin1, :utf8) do
        converted when is_binary(converted) -> converted
        _ -> ""
      end
    end
  end

  defp printable(_), do: nil

  @doc """
  The parser identifiers this detector may return.

  Guaranteed at compile time to be a subset of
  `CashLens.Parsers.AccountFile.valid_parsers/0`, so the detector's output
  vocabulary cannot drift away from the accepted one.
  """
  @spec detectable_parsers() :: [String.t()]
  def detectable_parsers, do: @detectable_parsers
end
