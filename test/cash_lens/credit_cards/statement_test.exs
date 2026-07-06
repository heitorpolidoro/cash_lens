defmodule CashLens.CreditCards.StatementTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards.Statement

  test "changeset requires account_id" do
    changeset = Statement.changeset(%Statement{}, %{})
    refute changeset.valid?
    assert %{account_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset accepts full attrs" do
    attrs = %{
      account_id: Ecto.UUID.generate(),
      competencia: ~D[2026-06-01],
      due_date: ~D[2026-06-15],
      total_a_pagar: Decimal.new("3812.40"),
      source_file: "ourocard_2026-06.pdf"
    }

    assert Statement.changeset(%Statement{}, attrs).valid?
  end
end
