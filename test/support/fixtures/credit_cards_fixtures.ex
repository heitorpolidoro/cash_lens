defmodule CashLens.CreditCardsFixtures do
  @moduledoc "Test helpers for CashLens.CreditCards. Accepts `:user` for an explicit owner."

  alias CashLens.Tenancy

  def statement_fixture(attrs \\ %{}) do
    {user, attrs} = Tenancy.pop_user(attrs)

    account =
      Map.get_lazy(attrs, :account, fn ->
        CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, user: user})
      end)

    {:ok, statement} =
      Tenancy.acting_as(user, fn ->
        attrs
        |> Map.drop([:account])
        |> Enum.into(%{
          account_id: account.id,
          competencia: ~D[2026-06-01],
          due_date: ~D[2026-06-15],
          total_a_pagar: Decimal.new("100.00"),
          source_file: "fatura.pdf"
        })
        |> CashLens.CreditCards.create_statement()
      end)

    statement
  end
end
