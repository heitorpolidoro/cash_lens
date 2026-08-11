defmodule CashLens.Parsers.PDFParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Parser for PDF content (text-based) for various providers.
  """

  require Logger

  @mercado_pago_line_regex ~r/^(\d{2}\/\d{2})\s+(.+?)(?:\s+Parcela\s+(\d+)\s+de\s+(\d+))?\s+R\$\s*([\d.]+,\d{2})\s*$/

  # Matches the transaction table's closing "Total" row, the same shape
  # `extract_mercado_pago_total/1` looks for — used to terminate the
  # `:purchases` section so nothing past the table is mis-parsed as a row.
  @mercado_pago_total_line_regex ~r/^Total\s+R\$/

  @doc """
  Parses the text content of a PDF statement.
  """
  def parse(text, :sem_parar) do
    # 1. Extract Plan/Monthly Fee
    plan_transactions = extract_plan_fee(text)

    # 2. Extract Usages (Tolls, Parking, etc.)
    usage_transactions = extract_usages(text)

    plan_transactions ++ usage_transactions
  end

  def parse(text, :bradesco_card) do
    statement_date = extract_statement_date(text)
    lines = String.split(text, "\n")

    # Detect max width from transaction lines (supporting optional leading minus/plus signs)
    regex = ~r/^\s*\d{2}\/\d{2}\s+.*?\s+[-+]?[\d.]+,\d{2}(?:\s*-)?/
    max_width = detect_max_width(lines, regex)

    # Clean lines by truncating to max_width
    cleaned_lines = Enum.map(lines, &String.slice(&1, 0, max_width))

    state = process_lines(cleaned_lines, statement_date)
    state = finalize_current_tx(state)
    state.parsed_transactions
  end

  def parse(text, :mercado_pago_card) do
    statement_date = extract_statement_date(text)
    lines = String.split(text, "\n")

    {transactions, _section} =
      Enum.reduce(lines, {[], :none}, &mercado_pago_reduce_line(&1, &2, statement_date))

    transactions = Enum.reverse(transactions)
    check_mercado_pago_reconciliation(transactions, text)
    transactions
  end

  defp mercado_pago_reduce_line(line, {acc, section}, statement_date) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {acc, section}

      Regex.match?(@mercado_pago_total_line_regex, trimmed) ->
        {acc, :none}

      String.contains?(trimmed, "Movimentações na fatura") and section == :none ->
        {acc, :payment}

      String.starts_with?(trimmed, "Cartão Visa") ->
        {acc, :purchases}

      section in [:payment, :purchases] ->
        accumulate_mercado_pago_line(trimmed, section, acc, statement_date)

      true ->
        {acc, section}
    end
  end

  defp accumulate_mercado_pago_line(trimmed, section, acc, statement_date) do
    case parse_mercado_pago_line(trimmed, section, statement_date) do
      nil -> {acc, section}
      tx -> {[tx | acc], section}
    end
  end

  # Passive detection only (Finding 1): compares the parsed purchase-row
  # total against the fatura's own extracted "Total" so a row that silently
  # failed to match `@mercado_pago_line_regex` (e.g. an unhandled refund/
  # estorno sign format) surfaces as a warning instead of vanishing without
  # a trace. Never changes the returned transaction list.
  defp check_mercado_pago_reconciliation(transactions, text) do
    case extract_mercado_pago_total(text) do
      nil ->
        :ok

      expected_total ->
        purchases_total =
          transactions
          |> Enum.filter(&Decimal.negative?(&1.amount))
          |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))
          |> Decimal.abs()

        unless Decimal.equal?(purchases_total, expected_total) do
          Logger.warning(
            "Mercado Pago fatura reconciliation mismatch: parsed purchases total " <>
              "#{purchases_total} does not match the statement's Total #{expected_total} " <>
              "— a transaction row may have been silently dropped during parsing."
          )
        end
    end
  end

  defp parse_mercado_pago_line(line, section, statement_date) do
    case Regex.run(@mercado_pago_line_regex, line) do
      [_, date_str, desc, parcela_n, parcela_m, amount_str] ->
        %{
          date: resolve_purchase_date(date_str, statement_date),
          time: nil,
          description: mercado_pago_description(desc, parcela_n, parcela_m),
          amount: mercado_pago_amount(amount_str, section)
        }

      _ ->
        nil
    end
  end

  defp mercado_pago_description(desc, "", ""), do: desc
  defp mercado_pago_description(desc, n, m), do: desc <> " PARC #{n}/#{m}"

  defp mercado_pago_amount(amount_str, :payment), do: parse_amount(amount_str)
  defp mercado_pago_amount(amount_str, :purchases), do: Decimal.negate(parse_amount(amount_str))

  defp detect_max_width(lines, regex) do
    widths =
      Enum.flat_map(lines, fn line ->
        case Regex.run(regex, line, return: :index) do
          [{start, len}] -> [start + len]
          _ -> []
        end
      end)

    if Enum.empty?(widths), do: 9999, else: Enum.max(widths) + 3
  end

  defp determine_in_table?(line_upper, current_in_table) do
    cond do
      (String.contains?(line_upper, "DATA") and
         String.contains?(line_upper, [
           "HISTÓRICO",
           "DESCRIÇÃO",
           "LANÇAMENTOS",
           "HISTORICO",
           "DESCRICAO"
         ])) or
        String.contains?(line_upper, "LANÇAMENTOS") or
          String.contains?(line_upper, "LANÇAMENTO") ->
        true

      String.contains?(line_upper, [
        "TOTAL PARA",
        "TOTAL DA FATURA",
        "TOTAL DE PARCELAS",
        "TOTAL DA FATURA EM REAL"
      ]) ->
        false

      true ->
        current_in_table
    end
  end

  defp process_lines(cleaned_lines, statement_date) do
    state = %{
      in_table?: false,
      parsed_transactions: [],
      current_tx: nil,
      buffer: []
    }

    Enum.reduce(cleaned_lines, state, fn line, acc ->
      trimmed = String.trim(line)
      line_upper = String.upcase(trimmed)

      in_table? = determine_in_table?(line_upper, acc.in_table?)
      acc = %{acc | in_table?: in_table?}

      if acc.in_table? do
        process_table_line(trimmed, acc, statement_date)
      else
        finalize_current_tx(acc)
      end
    end)
  end

  defp extract_plan_fee(text) do
    # Pattern: Plano Contratado ... R$ 58,17
    # Using scan to ensure we get all (though usually it's just one)
    regex = ~r/Plano Contratado.*?(\d{2}\/\d{2}\/\d{2}|[A-Z_]+)\s+R\$\s+([\d,.]+)/s

    Regex.scan(regex, text)
    |> Enum.map(fn [_, date_str, amount_str] ->
      %{
        date: parse_date(date_str),
        time: nil,
        description: "Mensalidade Sem Parar",
        amount: negate_if_not_zero(parse_amount(amount_str))
      }
    end)
  end

  defp negate_if_not_zero(amt) do
    if Decimal.eq?(amt, 0), do: Decimal.new("0"), else: Decimal.mult(amt, -1)
  end

  defp extract_usages(text) do
    lines = String.split(text, "\n")

    # regex for line 1: optional vehicle plate, date, description, amount
    regex_l1 =
      ~r/^(?!.*Plano Contratado)(?:[A-Z0-9]{7})?\s*(\d{2}\/\d{2}\/\d{2}|[A-Z_]+)\s+(.*?)\s+R\$\s+([\d,.]+)/

    # regex for line 2: "às" time, more description
    regex_l2 = ~r/\s+às\s+(\d{2}:\d{2}:\d{2}|[A-Z_]+)\s+(.*)/

    {transactions, last_tx} =
      Enum.reduce(lines, {[], nil}, fn line, state ->
        process_usage_line(line, state, regex_l1, regex_l2)
      end)

    # Final flush
    final_acc = if last_tx, do: [last_tx | transactions], else: transactions
    Enum.reverse(final_acc)
  end

  defp process_usage_line(line, {acc, last_tx}, regex_l1, regex_l2) do
    cond do
      # 1. Matches line 1 (New Transaction starting)
      Regex.match?(regex_l1, line) ->
        [_, date_str, desc, amount_str] = Regex.run(regex_l1, line)

        new_tx = %{
          date: parse_date(date_str),
          time: nil,
          description: String.trim(desc),
          amount: negate_if_not_zero(parse_amount(amount_str))
        }

        # If there was a previous tx, save it now
        acc = if last_tx, do: [last_tx | acc], else: acc
        {acc, new_tx}

      # 2. Matches line 2 (Continuing last transaction)
      last_tx && Regex.match?(regex_l2, line) ->
        [_, time_str, extra_desc] = Regex.run(regex_l2, line)

        updated_tx = %{
          last_tx
          | time: parse_time(time_str),
            description: (last_tx.description <> " " <> String.trim(extra_desc)) |> String.trim()
        }

        # Finish this TX and add to list
        {[updated_tx | acc], nil}

      # 3. Random line
      true ->
        {acc, last_tx}
    end
  end

  defp parse_date(date_string) do
    case String.split(date_string, "/") do
      [d, m, y] -> do_parse_date(d, m, y)
      _ -> Date.utc_today()
    end
  end

  defp do_parse_date(d, m, y) do
    with {d_int, ""} <- Integer.parse(d),
         {m_int, ""} <- Integer.parse(m),
         {y_int, ""} <- Integer.parse(y),
         year = if(y_int < 100, do: 2000 + y_int, else: y_int),
         {:ok, date} <- Date.new(year, m_int, d_int) do
      date
    else
      _ -> Date.utc_today()
    end
  end

  defp parse_time(time_string) do
    case String.split(time_string, ":") do
      [h, m, s] ->
        with {h_int, ""} <- Integer.parse(h),
             {m_int, ""} <- Integer.parse(m),
             {s_int, ""} <- Integer.parse(s),
             {:ok, time} <- Time.new(h_int, m_int, s_int) do
          time
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_amount(amount_string) do
    clean_string =
      amount_string
      |> String.replace(".", "")
      |> String.replace(",", ".")

    case Decimal.cast(clean_string) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp process_table_line("", state, _statement_date) do
    finalize_current_tx(state)
  end

  defp process_table_line(trimmed, state, statement_date) do
    if ignored_line?(trimmed) do
      state
    else
      do_process_table_line(trimmed, state, statement_date)
    end
  end

  defp do_process_table_line(trimmed, state, statement_date) do
    regex = ~r/^(\d{2}\/\d{2})\s+(.*?)\s+([-+]?[\d.]+,\d{2}(?:\s*-)?)(?:\s{2,}|$)/

    case Regex.run(regex, trimmed) do
      [_, date_str, desc_str, amount_str] ->
        state = if state.current_tx, do: finalize_current_tx(state), else: state

        combined_desc =
          (state.buffer ++ [desc_str])
          |> Enum.join(" ")
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        new_tx = %{
          date: resolve_purchase_date(date_str, statement_date),
          time: nil,
          description: combined_desc,
          amount: parse_and_adjust_amount(amount_str)
        }

        %{state | current_tx: new_tx, buffer: []}

      nil ->
        %{state | buffer: state.buffer ++ [trimmed]}
    end
  end

  defp finalize_current_tx(state) do
    if state.current_tx do
      final_desc =
        [state.current_tx.description | state.buffer]
        |> Enum.join(" ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      final_tx = %{state.current_tx | description: final_desc}

      %{
        state
        | parsed_transactions: state.parsed_transactions ++ [final_tx],
          current_tx: nil,
          buffer: []
      }
    else
      %{state | buffer: []}
    end
  end

  defp ignored_line?(line) do
    upper = String.upcase(line)

    String.contains?(upper, [
      "DESCRIÇÃO",
      "DESCRICAO",
      "NACIONAIS",
      "INTERNACIONAIS",
      "HISTÓRICO",
      "HISTORICO",
      "VALOR R$",
      "CIDADE",
      "COTAÇÃO",
      "COTACAO",
      "LIMITE",
      "DÓLAR",
      "DOLAR",
      "PÁG.",
      "PAG.",
      "PÁGINA",
      "PAGINA",
      "SALDO ANTERIOR",
      "CARTÃO",
      "CARTAO",
      "DATA HISTÓRICO",
      "DATA HISTORICO",
      "LANÇAMENTOS",
      "LANÇAMENTO",
      "LANCA-MENTOS",
      "LANCA-MENTO",
      "**"
    ]) or String.match?(upper, ~r/^\d+\s*$/) or String.match?(upper, ~r/^[X.\s]+$/)
  end

  defp parse_and_adjust_amount(amount_str) do
    is_credit = String.ends_with?(amount_str, "-")

    clean_str =
      amount_str
      |> String.replace("-", "")
      |> String.replace(".", "")
      |> String.replace(",", ".")
      |> String.trim()

    amt =
      case Decimal.cast(clean_str) do
        {:ok, decimal} -> decimal
        :error -> Decimal.new("0")
      end

    if is_credit or String.starts_with?(amount_str, "-"),
      do: Decimal.abs(amt),
      else: Decimal.negate(amt)
  end

  defp extract_statement_date(text) do
    extract_with_regexes(text, [
      {~r/Vencimento\s*(?:\r?\n\s*)?(\d{2}\/\d{2}\/(\d{4}))/i, 1},
      {~r/Vencimento.*?(\d{2}\/\d{2}\/\d{4})/s, 1},
      {~r/(\d{2})\/(\d{2})\/(\d{4})/, 0}
    ])
  end

  defp extract_with_regexes(_text, []), do: Date.utc_today()

  defp extract_with_regexes(text, [{regex, index} | rest]) do
    case Regex.run(regex, text) do
      nil ->
        extract_with_regexes(text, rest)

      matches ->
        process_matches(matches, index, text, rest)
    end
  end

  defp process_matches(matches, index, text, rest) do
    case parse_extracted_date(matches, index) do
      {:ok, date} -> date
      :error -> extract_with_regexes(text, rest)
    end
  end

  defp parse_extracted_date(matches, index) do
    date_str = Enum.at(matches, index)

    case String.split(date_str, "/") do
      [d, m, y] ->
        with {d_int, _} <- Integer.parse(d),
             {m_int, _} <- Integer.parse(m),
             {y_int, _} <- Integer.parse(y),
             {:ok, date} <- Date.new(y_int, m_int, d_int) do
          {:ok, date}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Statement-level metadata for a credit-card PDF: due date (Vencimento),
  total_a_pagar (the "TOTAL DA FATURA" amount for Bradesco-style layouts,
  previously used only as an end-of-table marker, or the "Total a pagar" /
  "Resumo da fatura" total for Mercado Pago's layout) and competencia
  (first day of the due month). Any field is nil when the source does not
  carry it.
  """
  def extract_statement_meta(text) do
    due = extract_statement_date_or_nil(text)

    %{
      due_date: due,
      total_a_pagar: extract_total_amount(text),
      competencia: due && Date.beginning_of_month(due)
    }
  end

  # Mirrors the proven `extract_statement_date/1` Vencimento matching (a strict
  # "label then date" form plus a lenient dotall fallback for layouts where the
  # date sits apart from the label), but returns nil instead of falling back to
  # today's date — statement metadata must be absent (nil) when the source
  # carries no due date (e.g. OFX), never a fabricated one.
  defp extract_statement_date_or_nil(text) do
    regexes = [
      ~r/Vencimento\s*(?:\r?\n\s*)?(\d{2})\/(\d{2})\/(\d{4})/i,
      ~r/Vencimento.*?(\d{2})\/(\d{2})\/(\d{4})/s
    ]

    Enum.find_value(regexes, fn regex ->
      case Regex.run(regex, text) do
        [_, d, m, y] -> build_date(y, m, d)
        _ -> nil
      end
    end)
  end

  defp build_date(y, m, d) do
    case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp extract_total(text) do
    regex = ~r/TOTAL (?:DA FATURA|PARA)[^\d]*?([\d.]+,\d{2})/i

    case Regex.run(regex, text) do
      [_, amount_str] -> parse_amount(amount_str) |> Decimal.abs()
      _ -> nil
    end
  end

  # Mercado Pago's fatura repeats "Total da fatura de <mês anterior>" (a
  # different month's total) before its own real total — text that
  # `extract_total/1`'s "TOTAL DA FATURA" pattern (built for Bradesco) would
  # otherwise match instead of the real one. Route by a marker unique to
  # Mercado Pago's layout ("Total a pagar", not present in Bradesco's real
  # statements) rather than widening the shared regex to cover both formats
  # unsafely.
  defp extract_total_amount(text) do
    if String.contains?(text, "Total a pagar") do
      extract_mercado_pago_total(text)
    else
      extract_total(text)
    end
  end

  # Real Mercado Pago faturas contain three lines matching a bare
  # "Total ... R$ X,XX" shape: the correct "Resumo da fatura" total, the
  # transaction table's closing "Total" row (same, correct value), and a
  # later, unrelated "Lançamentos futuros" section's own "Total" (a
  # DIFFERENT value). Scoping the search to the "Resumo da fatura" section
  # (up to the "Lançamentos futuros" marker, when present) picks the right
  # occurrence structurally instead of relying on document order.
  defp extract_mercado_pago_total(text) do
    regex = ~r/Total\s+R\$\s*([\d.]+,\d{2})/

    case Regex.run(regex, mercado_pago_total_scope(text)) do
      [_, amount_str] -> parse_amount(amount_str) |> Decimal.abs()
      _ -> nil
    end
  end

  defp mercado_pago_total_scope(text) do
    case String.split(text, "Resumo da fatura", parts: 2) do
      [_, rest] ->
        rest
        |> String.split("Lançamentos futuros", parts: 2)
        |> List.first()

      _ ->
        text
    end
  end

  defp resolve_purchase_date(date_str, statement_date) do
    [d, m] = String.split(date_str, "/")
    {d_int, _} = Integer.parse(d)
    {m_int, _} = Integer.parse(m)

    year =
      if m_int > statement_date.month do
        statement_date.year - 1
      else
        statement_date.year
      end

    case Date.new(year, m_int, d_int) do
      {:ok, date} -> date
      _ -> statement_date
    end
  end
end
