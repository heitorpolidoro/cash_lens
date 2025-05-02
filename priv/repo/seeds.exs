# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     CashLens.Repo.insert!(%CashLens.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias CashLens.Transactions.Transaction
alias CashLens.Repo

# Add some sample transactions
[
  %{
    date: ~D[2024-06-01],
    time: ~T[12:00:00],
    reason: "Groceries",
    category: "Food",
    amount: Decimal.new("45.67")
  },
  %{
    date: ~D[2024-06-02],
    time: ~T[14:30:00],
    reason: "Gas",
    category: "Transportation",
    amount: Decimal.new("30.00")
  },
  %{
    date: ~D[2024-06-03],
    time: ~T[18:15:00],
    reason: "Dinner",
    category: "Food",
    amount: Decimal.new("65.50")
  }
]
|> Enum.each(fn transaction_data ->
  %Transaction{}
  |> Transaction.changeset(transaction_data)
  |> Repo.insert!()
end)

IO.puts("Database seeded with sample transactions!")
