defmodule CashLens.Transactions.PluggyMatcher do
  @moduledoc """
  Annotates transactions in-memory with the `pluggy_category` from cached Pluggy entries.

  Matches transactions based on:
    * Same account (`account_id`)
    * Same amount (`Decimal.equal?/2`)
    * Date within a configurable day tolerance (default: ±4 calendar days)
    * Minimal absolute day difference (`abs(Date.diff/2)`)
    * Description similarity as tie-breaker
  """

  alias CashLens.Pluggy.LivePreview.Entry
  alias CashLens.Transactions.Transaction

  @default_day_tolerance 4

  @doc """
  Annotates a list of `%Transaction{}` structs with `pluggy_category` by matching
  against the provided list of `%LivePreview.Entry{}` structs.
  """
  @spec annotate([Transaction.t()], [Entry.t()] | map(), keyword()) :: [Transaction.t()]
  def annotate(transactions, entries, opts \\ [])

  def annotate(transactions, nil, _opts), do: transactions
  def annotate(transactions, [], _opts), do: transactions
  def annotate([], _entries, _opts), do: []

  def annotate(transactions, entries_map, opts)
      when is_map(entries_map) and not is_struct(entries_map) do
    entries = entries_map |> Map.values() |> List.flatten()
    annotate(transactions, entries, opts)
  end

  def annotate(transactions, entries, opts) when is_list(entries) do
    day_tolerance = Keyword.get(opts, :day_tolerance, @default_day_tolerance)

    valid_entries =
      Enum.filter(entries, fn entry ->
        is_binary(entry.pluggy_category) and String.trim(entry.pluggy_category) != ""
      end)

    entries_by_account = Enum.group_by(valid_entries, & &1.account_id)

    {annotated, _remaining_entries} =
      Enum.reduce(transactions, {[], entries_by_account}, fn tx, acc ->
        annotate_transaction(tx, acc, day_tolerance)
      end)

    Enum.reverse(annotated)
  end

  defp annotate_transaction(tx, {acc_txs, acc_entries}, day_tolerance) do
    account_entries = Map.get(acc_entries, tx.account_id, [])

    case find_best_match(tx, account_entries, day_tolerance) do
      nil ->
        {[tx | acc_txs], acc_entries}

      {matched_entry, remaining_for_account} ->
        updated_tx = apply_pluggy_category(tx, matched_entry.pluggy_category)
        updated_entries = Map.put(acc_entries, tx.account_id, remaining_for_account)
        {[updated_tx | acc_txs], updated_entries}
    end
  end

  defp apply_pluggy_category(%{pluggy_category: nil} = tx, category),
    do: %{tx | pluggy_category: category}

  defp apply_pluggy_category(tx, _category), do: tx

  defp find_best_match(tx, entries, day_tolerance) do
    candidates =
      entries
      |> Enum.filter(fn entry ->
        Decimal.equal?(entry.amount, tx.amount) and
          abs(Date.diff(tx.date, entry.date)) <= day_tolerance
      end)

    case candidates do
      [] ->
        nil

      _ ->
        sorted =
          Enum.sort_by(candidates, fn entry ->
            day_dist = abs(Date.diff(tx.date, entry.date))
            sim = description_similarity(tx.description || "", entry.description || "")

            # Sort primarily by smallest day distance, tie-breaking by highest similarity
            {day_dist, -sim}
          end)

        best = hd(sorted)
        remaining = List.delete(entries, best)
        {best, remaining}
    end
  end

  defp description_similarity(desc1, desc2) do
    words1 = tokenize(desc1)
    words2 = tokenize(desc2)

    if words1 == [] or words2 == [] do
      0.0
    else
      set1 = MapSet.new(words1)
      set2 = MapSet.new(words2)
      intersection_size = MapSet.intersection(set1, set2) |> MapSet.size()
      union_size = MapSet.union(set1, set2) |> MapSet.size()
      intersection_size / union_size
    end
  end

  defp tokenize(str) do
    str
    |> Transaction.normalize_description()
    |> String.replace(~r/[^A-Z0-9\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
  end
end
