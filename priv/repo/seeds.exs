alias CashLens.Categories.Category
alias CashLens.Repo

# Seeds run through `mix run`, with no session: name the owner explicitly via
# CASH_LENS_OPERATOR_EMAIL (or leave it unset when there is a single user).
user = CashLens.Ownership.operator_user!(System.get_env("CASH_LENS_OPERATOR_EMAIL"))

for {name, slug} <- [
      {"Valor Inicial", "initial_value"},
      {"Transferência", "transfer"},
      {"Cartão de Crédito", "cartao-de-credito"}
    ] do
  Repo.insert!(%Category{user_id: user.id, name: name, slug: slug}, on_conflict: :nothing)
end
