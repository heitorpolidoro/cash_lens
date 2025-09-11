alias CashLens.Repo
alias CashLens.Accounts.Account
alias CashLens.Categories.Category
alias CashLens.AutomaticTransfers.AutomaticTransfer

categories = [
  %{name: "Transfer"},
  %{name: "Adjust"},
  %{name: "Undefined"}
]

Enum.each(categories, fn category_attrs ->
  try do
    %Category{}
    |> Category.changeset(category_attrs)
    |> Repo.insert!()
  rescue
    Ecto.ConstraintError -> :already_exists
  end
end)

accounts = [
  %{name: "Conta Corrente", bank_name: "Banco do Brasil", type: "checking"},
  %{name: "BB Rende Fácil", bank_name: "Banco do Brasil", type: "savings"}
]

Enum.each(accounts, fn account_attrs ->
  try do
    %Account{}
    |> Account.changeset(account_attrs)
    |> Repo.insert()
  rescue
    Ecto.ConstraintError -> :already_exists
  end
end)

categories = [
  %{name: "Fuel"},
  %{name: "Education"},
  %{name: "House"},
  %{name: "Food"},
  %{name: "Market"},
  %{name: "Toll"},
  %{name: "Tax"}
]

Enum.each(categories, fn category_attrs ->
  try do
    %Category{}
    |> Category.changeset(category_attrs)
    |> Repo.insert()
  rescue
    Ecto.ConstraintError -> :already_exists
  end
end)

try do
  %AutomaticTransfer{}
  |> AutomaticTransfer.changeset(%{from_id: 2, to_id: 1})
  |> Repo.insert()
rescue
  Ecto.ConstraintError -> :already_exists
end
