defmodule CashLens.CreditCards.Matcher do
  @moduledoc "Auto-links a statement to its exact-amount payment on import."
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.CreditCards
  alias CashLens.Transactions.Transaction

  @window_days 15

  def auto_link(statement, line_total) do
    with category when not is_nil(category) <-
           CashLens.Categories.get_category_by_slug("cartao-de-credito") do
      target = statement.total_a_pagar || line_total
      ref = statement.due_date || statement.competencia

      candidates =
        from(t in Transaction,
          where: t.category_id == ^category.id,
          where: t.account_id != ^statement.account_id,
          where: is_nil(t.parent_transaction_id),
          where: t.amount == ^target or t.amount == ^Decimal.negate(target)
        )
        |> Repo.all()
        |> Enum.filter(&within_window?(&1, ref))

      case candidates do
        [payment] ->
          {:ok, _} = CreditCards.link_payment(statement, payment.id)
          {:linked, payment}

        [] ->
          :no_match

        _ ->
          :ambiguous
      end
    else
      _ -> :no_match
    end
  end

  defp within_window?(_payment, nil), do: true
  defp within_window?(payment, ref), do: abs(Date.diff(payment.date, ref)) <= @window_days
end
