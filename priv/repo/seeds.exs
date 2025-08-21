alias CashLens.Repo
alias CashLens.Categories.Category

categories = [
  %{name: "Transfer"},
  %{name: "Adjust"}
]

Enum.each(categories, fn category_attrs ->
  %Category{}
  |> Category.changeset(category_attrs)
  |> Repo.insert!()
end)
