defmodule CashLens.CreditCardsFixtures do
  @moduledoc "Test helpers for CashLens.CreditCards."

  def statement_fixture(attrs \\ %{}) do
    account =
      Map.get_lazy(attrs, :account, fn ->
        CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      end)

    {:ok, statement} =
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

    statement
  end
end
