defmodule CashLens.Accounts.ScopesTest do
  use CashLens.DataCase, async: true

  import Ecto.Query

  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Accounts.Scopes
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  describe "cash_accounts_only/1" do
    test "excludes a transaction sitting on a credit-card account" do
      card_account = account_fixture(%{is_credit_card: true})
      transaction = transaction_fixture(%{account_id: card_account.id})

      refute transaction.id in ids(Scopes.cash_accounts_only(Transaction))
    end

    test "keeps a transaction sitting on a bank account" do
      bank_account = account_fixture(%{is_credit_card: false})
      transaction = transaction_fixture(%{account_id: bank_account.id})

      assert transaction.id in ids(Scopes.cash_accounts_only(Transaction))
    end
  end

  describe "cash_account_binding/2" do
    test "returns the same ids as the joining form over the same data" do
      bank_account = account_fixture(%{is_credit_card: false})
      card_account = account_fixture(%{is_credit_card: true})

      kept = transaction_fixture(%{account_id: bank_account.id})
      dropped = transaction_fixture(%{account_id: card_account.id})

      joining_ids = ids(Scopes.cash_accounts_only(Transaction))

      pre_named_ids =
        from(t in Transaction, join: a in assoc(t, :account), as: :acct)
        |> Scopes.cash_account_binding(:acct)
        |> ids()

      assert joining_ids == pre_named_ids
      assert kept.id in pre_named_ids
      refute dropped.id in pre_named_ids
    end
  end
end
