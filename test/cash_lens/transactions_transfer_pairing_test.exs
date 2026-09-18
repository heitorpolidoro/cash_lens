defmodule CashLens.TransactionsTransferPairingTest do
  use CashLens.DataCase, async: false

  import Ecto.Query
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  setup do
    Repo.delete_all(CashLens.Transactions.BulkIgnorePattern)
    transfer_cat = category_fixture(%{name: "Transfer", slug: "transfer"})
    acc_a = account_fixture(%{name: "Conta A", bank: "BB"})
    acc_b = account_fixture(%{name: "Conta B", bank: "Itau"})
    %{transfer_cat: transfer_cat, acc_a: acc_a, acc_b: acc_b}
  end

  # Creates a transaction and clears any transfer_key assigned by the ingestion
  # pipeline, so the row is visible to the pairing helpers.
  defp unmatched_transaction(attrs) do
    tx = transaction_fixture(attrs)
    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [transfer_key: nil])
    Repo.get!(Transaction, tx.id)
  end

  # The ingestion pipeline links same-date opposite pairs on the spot; clearing
  # every key afterwards puts the rows back in the "waiting to be reconciled"
  # state these helpers are about.
  defp clear_all_transfer_keys do
    Repo.update_all(Transaction, set: [transfer_key: nil])
  end

  describe "list_transfer_suggestions/0" do
    test "pairs a debit and a credit of the same amount within the date window", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      out =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-03-01]
        })

      inc =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-03-03]
        })

      assert [{suggested_out, suggested_in}] = Transactions.list_transfer_suggestions()
      assert suggested_out.id == out.id
      assert suggested_in.id == inc.id
    end

    test "does not pair transactions more than 3 days apart", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-100.00",
        date: ~D[2026-03-01]
      })

      unmatched_transaction(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "100.00",
        date: ~D[2026-03-05]
      })

      assert Transactions.list_transfer_suggestions() == []
    end

    test "uses each transaction in at most one suggestion, preferring the closest date", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      out =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-03-01]
        })

      near =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-03-01]
        })

      _far =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-03-03]
        })

      clear_all_transfer_keys()

      assert [{suggested_out, suggested_in}] = Transactions.list_transfer_suggestions()
      assert suggested_out.id == out.id
      assert suggested_in.id == near.id
    end
  end

  describe "list_unmatched_transfers_without_suggestion/0" do
    test "excludes transactions that already have a suggested counterpart", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "-100.00",
        date: ~D[2026-03-01]
      })

      unmatched_transaction(%{
        account_id: b.id,
        category_id: cat.id,
        amount: "100.00",
        date: ~D[2026-03-02]
      })

      lonely =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-77.00",
          date: ~D[2026-03-10]
        })

      ids =
        Transactions.list_unmatched_transfers_without_suggestion() |> Enum.map(& &1.id)

      assert ids == [lonely.id]
    end
  end

  describe "list_transfer_link_candidates/1" do
    test "returns opposite-sign candidates with amount and day differences", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-03-01]
        })

      exact =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-03-02]
        })

      approximate =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "99.50",
          date: ~D[2026-03-04]
        })

      candidates = Transactions.list_transfer_link_candidates(origin)

      assert [first, second] = candidates
      assert first.transaction.id == exact.id
      assert Decimal.equal?(first.amount_diff, Decimal.new("0.00"))
      assert first.day_diff == 1

      assert second.transaction.id == approximate.id
      assert Decimal.equal?(second.amount_diff, Decimal.new("0.50"))
      assert second.day_diff == 3
    end

    test "never returns the origin, same-account or already linked transactions", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-100.00",
          date: ~D[2026-03-01]
        })

      # Same account, opposite sign.
      unmatched_transaction(%{
        account_id: a.id,
        category_id: cat.id,
        amount: "100.00",
        date: ~D[2026-03-01]
      })

      linked =
        unmatched_transaction(%{
          account_id: b.id,
          category_id: cat.id,
          amount: "100.00",
          date: ~D[2026-03-01]
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^linked.id),
        set: [transfer_key: Ecto.UUID.generate()]
      )

      assert Transactions.list_transfer_link_candidates(origin) == []
    end
  end

  describe "create_mirror_transaction/2" do
    test "creates the symmetric transaction on the destination account and links the pair", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-250.00",
          description: "PIX enviado",
          date: ~D[2026-03-01]
        })

      assert {:ok, mirror} = Transactions.create_mirror_transaction(origin.id, b.id)

      assert mirror.account_id == b.id
      assert mirror.date == origin.date
      assert Decimal.equal?(mirror.amount, Decimal.new("250.00"))
      assert mirror.category_id == cat.id
      refute is_nil(mirror.transfer_key)

      assert Repo.get!(Transaction, origin.id).transfer_key == mirror.transfer_key
    end

    test "refuses to mirror onto the origin account", %{
      transfer_cat: cat,
      acc_a: a
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-250.00",
          date: ~D[2026-03-01]
        })

      assert {:error, :same_account} = Transactions.create_mirror_transaction(origin.id, a.id)
    end

    test "refuses to mirror an already linked transaction", %{
      transfer_cat: cat,
      acc_a: a,
      acc_b: b
    } do
      origin =
        unmatched_transaction(%{
          account_id: a.id,
          category_id: cat.id,
          amount: "-250.00",
          date: ~D[2026-03-01]
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^origin.id),
        set: [transfer_key: Ecto.UUID.generate()]
      )

      assert {:error, :already_linked} = Transactions.create_mirror_transaction(origin.id, b.id)
    end
  end
end
