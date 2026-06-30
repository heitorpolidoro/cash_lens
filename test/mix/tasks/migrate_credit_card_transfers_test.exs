defmodule Mix.Tasks.MigrateCreditCardTransfersTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import ExUnit.CaptureLog

  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule

  defp insert_raw(attrs) do
    %Transaction{} |> Transaction.changeset(attrs) |> Repo.insert!()
  end

  defp link(tx_a, tx_b) do
    key = Ecto.UUID.generate()

    {2, _} =
      from(t in Transaction, where: t.id in [^tx_a.id, ^tx_b.id])
      |> Repo.update_all(set: [transfer_key: key])

    key
  end

  test "migrates a pair covered by an active mirror-creating TransferRule" do
    transfer_cat = category_fixture(%{name: "Transferência", slug: "transfer"})
    cc_cat = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    Repo.insert!(%TransferRule{
      description_patterns: ["fatura"],
      source_account_id: checking.id,
      destination_account_id: card.id,
      create_mirror: true
    })

    payment =
      insert_raw(%{
        account_id: checking.id,
        category_id: transfer_cat.id,
        amount: "-500.00",
        date: ~D[2026-01-15],
        description: "Pagamento fatura"
      })

    mirror =
      insert_raw(%{
        account_id: card.id,
        category_id: transfer_cat.id,
        amount: "500.00",
        date: ~D[2026-01-15],
        description: "Pagamento fatura"
      })

    link(payment, mirror)

    real_purchase =
      insert_raw(%{
        account_id: card.id,
        amount: "-500.00",
        date: ~D[2026-01-10],
        description: "Uber"
      })

    capture_log(fn -> Mix.Tasks.MigrateCreditCardTransfers.run([]) end)

    updated_payment = Repo.get!(Transaction, payment.id)
    assert updated_payment.category_id == cc_cat.id
    assert is_nil(updated_payment.transfer_key)
    assert is_nil(Repo.get(Transaction, mirror.id))
    assert Repo.get!(Transaction, real_purchase.id).parent_transaction_id == updated_payment.id
  end

  test "aborts without deleting anything when eligible pairs exceed the safety threshold" do
    transfer_cat = category_fixture(%{name: "Transferência", slug: "transfer"})
    category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    Repo.insert!(%TransferRule{
      description_patterns: ["fatura"],
      source_account_id: checking.id,
      destination_account_id: card.id,
      create_mirror: true
    })

    pairs =
      for i <- 1..501 do
        payment =
          insert_raw(%{
            account_id: checking.id,
            category_id: transfer_cat.id,
            amount: "-#{i}.00",
            date: ~D[2026-01-15],
            description: "Pagamento fatura #{i}"
          })

        mirror =
          insert_raw(%{
            account_id: card.id,
            category_id: transfer_cat.id,
            amount: "#{i}.00",
            date: ~D[2026-01-15],
            description: "Pagamento fatura #{i}"
          })

        link(payment, mirror)
        {payment, mirror}
      end

    log =
      capture_log(fn -> Mix.Tasks.MigrateCreditCardTransfers.run([]) end)

    assert log =~ "abort"

    Enum.each(pairs, fn {payment, mirror} ->
      reloaded_payment = Repo.get!(Transaction, payment.id)
      assert reloaded_payment.category_id == transfer_cat.id
      refute is_nil(reloaded_payment.transfer_key)
      assert Repo.get!(Transaction, mirror.id)
    end)
  end

  test "does not touch a transfer_key pair with no matching TransferRule" do
    transfer_cat = category_fixture(%{name: "Transferência", slug: "transfer"})
    category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
    checking = account_fixture(%{is_credit_card: false})
    card = account_fixture(%{is_credit_card: true})

    manual_a =
      insert_raw(%{
        account_id: checking.id,
        category_id: transfer_cat.id,
        amount: "-300.00",
        date: ~D[2026-02-01],
        description: "Transferência manual"
      })

    manual_b =
      insert_raw(%{
        account_id: card.id,
        category_id: transfer_cat.id,
        amount: "300.00",
        date: ~D[2026-02-01],
        description: "Transferência manual"
      })

    link(manual_a, manual_b)

    capture_log(fn -> Mix.Tasks.MigrateCreditCardTransfers.run([]) end)

    reloaded_a = Repo.get!(Transaction, manual_a.id)
    reloaded_b = Repo.get!(Transaction, manual_b.id)

    assert reloaded_a.category_id == transfer_cat.id
    assert reloaded_b != nil
    refute is_nil(reloaded_a.transfer_key)
    refute is_nil(reloaded_b.transfer_key)
  end
end
