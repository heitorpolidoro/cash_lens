alias CashLens.Repo
alias CashLens.Accounts.Account
alias CashLens.Categories.Category

categories = [
  %{name: "Transfer"},
  %{name: "Adjust"}
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
  %{name: "Conta Corrente", bank_name: "Banco do Brasil"}
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
  %{name: "Education"}
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
