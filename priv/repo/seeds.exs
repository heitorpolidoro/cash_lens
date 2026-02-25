alias CashLens.Repo
alias CashLens.Categories.Category

Repo.insert!(%Category{name: "Valor Inicial", slug: "initial_value"}, on_conflict: :nothing)
Repo.insert!(%Category{name: "Transferência", slug: "transfer"}, on_conflict: :nothing)
