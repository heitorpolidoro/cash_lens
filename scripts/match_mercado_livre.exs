# Script interativo de cruzamento e categorização de compras do Mercado Livre
require Logger
Logger.configure(level: :warning)
import Ecto.Query

alias CashLens.Repo
alias CashLens.Transactions.Transaction
alias CashLens.Categories.Category

json_path = "statements/mercado_livre_compras.json"

if not File.exists?(json_path) do
  IO.puts("Erro: O arquivo '#{json_path}' não foi encontrado. Por favor, execute o script do Playwright primeiro:")
  IO.puts("node scripts/extract_mercado_livre.js")
  System.halt(1)
end

# 1. Helpers for parsing date and amount
month_name_to_number = fn name ->
  cond do
    String.starts_with?(name, "jan") -> 1
    String.starts_with?(name, "fev") -> 2
    String.starts_with?(name, "mar") -> 3
    String.starts_with?(name, "abr") -> 4
    String.starts_with?(name, "mai") -> 5
    String.starts_with?(name, "jun") -> 6
    String.starts_with?(name, "jul") -> 7
    String.starts_with?(name, "ago") -> 8
    String.starts_with?(name, "set") -> 9
    String.starts_with?(name, "out") -> 10
    String.starts_with?(name, "nov") -> 11
    String.starts_with?(name, "dez") -> 12
    true -> raise "Mês desconhecido: #{name}"
  end
end

parse_pt_date = fn date_str ->
  clean = date_str |> String.downcase() |> String.trim()
  # Matches e.g. "24 de fev." or "15 de dezembro de 2025"
  regex = ~r/^(\d{1,2})\s+de\s+([a-zçáéíóúâêô]+)(?:\s+de\s+(\d{4}))?/u
  case Regex.run(regex, clean) do
    [_, day_str, month_name, year_str] when year_str != "" ->
      day = String.to_integer(day_str)
      month = month_name_to_number.(month_name)
      year = String.to_integer(year_str)
      Date.new(year, month, day)
      
    [_, day_str, month_name] ->
      day = String.to_integer(day_str)
      month = month_name_to_number.(month_name)
      today = Date.utc_today()
      year = if month > today.month, do: today.year - 1, else: today.year
      Date.new(year, month, day)
      
    _ ->
      {:error, :invalid_date}
  end
end

parse_amount = fn str ->
  str
  |> String.replace(".", "")
  |> String.replace(",", ".")
  |> String.trim()
  |> Decimal.cast()
  |> case do
    {:ok, dec} -> dec
    :error -> Decimal.new("0")
  end
end

# Get the "Mercado Livre" category
ml_category = Repo.one(from c in Category, where: c.name == "Mercado Livre")
if is_nil(ml_category) do
  IO.puts("Erro: A categoria 'Mercado Livre' não está cadastrada no banco de dados.")
  System.halt(1)
end

# Load and parse purchases JSON
purchases =
  json_path
  |> File.read!()
  |> Jason.decode!()
  |> Enum.map(fn p ->
    # Parse dates and amounts
    date =
      case parse_pt_date.(p["dateStr"]) do
        {:ok, d} -> d
        _ -> nil
      end

    amount = parse_amount.(p["priceStr"])

    %{
      order_id: p["orderId"],
      title: p["title"],
      date: date,
      amount: amount,
      raw_date: p["dateStr"],
      raw_price: p["priceStr"]
    }
  end)
  |> Enum.reject(&is_nil(&1.date))

IO.puts("Carregadas #{length(purchases)} compras extraídas do Mercado Livre.")

# Walk through each scraped purchase and search for candidates in DB
matched_results =
  Enum.reduce(purchases, {0, MapSet.new()}, fn purchase, {count, matched_ids} ->
    min_date = Date.add(purchase.date, -5)
    max_date = Date.add(purchase.date, 5)
    abs_amount = purchase.amount

    # Find candidate transactions in the database (with exact absolute amount and within 5 days)
    # Ignore those already categorized as Mercado Livre during DB query to keep matching clean,
    # but we will fetch all Mercado Livre transactions later for the final summary.
    db_candidates =
      Repo.all(
        from t in Transaction,
          join: a in assoc(t, :account),
          left_join: c in assoc(t, :category),
          where: t.date >= ^min_date and t.date <= ^max_date,
          where: fragment("abs(?)", t.amount) == ^abs_amount,
          where: is_nil(t.category_id) or t.category_id != ^ml_category.id,
          select: %{
            id: t.id,
            date: t.date,
            amount: t.amount,
            description: t.description,
            account_name: a.name,
            bank: a.bank,
            category_name: c.name
          }
      )

    case db_candidates do
      [] ->
        {count, matched_ids}

      [candidate] ->
        IO.puts("\nCompra: \"#{purchase.title}\" (#{purchase.raw_price} BRL) | ID: #{purchase.order_id}")
        IO.puts("Match: [#{candidate.date}] #{candidate.amount} BRL | #{candidate.description} (#{candidate.bank})")
        
        response = IO.gets("Categorizar? [s/n]: ") |> String.trim() |> String.downcase()

        if response in ["s", "sim", "y", "yes"] do
          tx_model = Repo.get!(Transaction, candidate.id)
          changeset = Transaction.changeset(tx_model, %{category_id: ml_category.id})
          Repo.update!(changeset)
          IO.puts("✅ Transação atualizada!")
          {count + 1, MapSet.put(matched_ids, candidate.id)}
        else
          {count, matched_ids}
        end

      multiple ->
        IO.puts("\nCompra: \"#{purchase.title}\" (#{purchase.raw_price} BRL) | ID: #{purchase.order_id}")
        IO.puts("Múltiplos Matches:")
        
        Enum.with_index(multiple)
        |> Enum.each(fn {cand, idx} ->
          IO.puts("  [#{idx + 1}] [#{cand.date}] #{cand.amount} BRL | #{cand.description} (#{cand.bank})")
        end)

        response = IO.gets("Selecione o número (ou 'n'): ") |> String.trim() |> String.downcase()

        case Integer.parse(response) do
          {num, ""} when num >= 1 and num <= length(multiple) ->
            selected = Enum.at(multiple, num - 1)
            tx_model = Repo.get!(Transaction, selected.id)
            changeset = Transaction.changeset(tx_model, %{category_id: ml_category.id})
            Repo.update!(changeset)
            IO.puts("✅ Transação ##{num} atualizada!")
            {count + 1, MapSet.put(matched_ids, selected.id)}

          _ ->
            {count, matched_ids}
        end
    end
  end)

{final_matched_count, final_matched_ids} = matched_results
IO.puts("\n============================================================")
IO.puts("Processamento concluído. #{final_matched_count} transações categorizadas nesta rodada.")

# 2. Final Summary check: DB transactions categorized as 'Mercado Livre' that did not match the JSON purchases
# We load all DB transactions categorized as 'Mercado Livre' and see which ones aren't in our matched list
# or didn't match the scraped list.
ml_db_transactions =
  Repo.all(
    from t in Transaction,
      join: a in assoc(t, :account),
      where: t.category_id == ^ml_category.id,
      select: %{
        id: t.id,
        date: t.date,
        amount: t.amount,
        description: t.description,
        account_name: a.name,
        bank: a.bank
      }
  )

# A database transaction categorized as Mercado Livre is unmatched if:
# - Its ID is not in our newly matched list
# - And there is no purchase in the scraped JSON with the exact same amount and close date (within 5 days)
unmatched_ml_db =
  Enum.filter(ml_db_transactions, fn db ->
    if MapSet.member?(final_matched_ids, db.id) do
      false
    else
      # Check if it matches any of the scraped purchases in memory
      abs_db_amount = Decimal.abs(db.amount)
      
      has_scraped_match =
        Enum.any?(purchases, fn p ->
          min = Date.add(p.date, -5)
          max = Date.add(p.date, 5)
          
          Date.compare(db.date, min) != :lt and
          Date.compare(db.date, max) != :gt and
          Decimal.eq?(abs_db_amount, p.amount)
        end)
      
      not has_scraped_match
    end
  end)

if length(unmatched_ml_db) > 0 do
  IO.puts("\n⚠️  Transações no DB categorizadas como 'Mercado Livre' sem correspondência no extrato:")
  Enum.each(unmatched_ml_db, fn db ->
    IO.puts("  - [#{db.date}] #{db.amount} BRL | #{db.description} (#{db.bank})")
  end)
else
  IO.puts("\n🎉 Tudo sincronizado! Todas as transações 'Mercado Livre' no DB possuem correspondência no extrato.")
end
IO.puts("============================================================\n")
