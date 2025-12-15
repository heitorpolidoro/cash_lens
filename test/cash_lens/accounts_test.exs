defmodule CashLens.AccountsTest do
  use ExUnit.Case, async: true

  alias CashLens.Accounts
  alias CashLens.Account
  alias CashLens.Repo
  alias MongoDB.BSON.ObjectId

  setup do
    # Ensure the test database is clean before each test
    :ok = Repo.delete_all(Account)
    %{user_id: ObjectId.generate()}
  end

  test "create_account/1 with valid attributes", %{user_id: user_id} do
    attrs = %{name: "Test Account", user_id: user_id}
    {:ok, account} = Accounts.create_account(attrs)
    assert account.name == "Test Account"
    assert account.user_id == user_id
    assert is_nil(account.updated_at) # We set updated_at: false in schema
    assert account.id != nil
  end

  test "create_account/1 with invalid attributes (missing name)" do
    attrs = %{user_id: ObjectId.generate()}
    {:error, changeset} = Accounts.create_account(attrs)
    assert changeset.errors[:name] == {"can't be blank", [validation: :required]}
  end

  test "get_account/1 returns an account" do
    user_id = ObjectId.generate()
    {:ok, account} = Accounts.create_account(%{name: "Another Account", user_id: user_id})
    fetched_account = Accounts.get_account(account.id)
    assert fetched_account.id == account.id
    assert fetched_account.name == account.name
  end

  test "get_account/1 returns nil for non-existent ID" do
    assert is_nil(Accounts.get_account(ObjectId.generate()))
  end

  test "list_accounts/0 returns all accounts" do
    user_id_1 = ObjectId.generate()
    user_id_2 = ObjectId.generate()
    Accounts.create_account(%{name: "Account 1", user_id: user_id_1})
    Accounts.create_account(%{name: "Account 2", user_id: user_id_2})

    accounts = Accounts.list_accounts()
    assert length(accounts) == 2
    assert Enum.any?(accounts, &(&1.name == "Account 1"))
    assert Enum.any?(accounts, &(&1.name == "Account 2"))
  end

  test "list_accounts_for_user/1 returns accounts for a specific user" do
    user_id_a = ObjectId.generate()
    user_id_b = ObjectId.generate()

    Accounts.create_account(%{name: "User A Account 1", user_id: user_id_a})
    Accounts.create_account(%{name: "User A Account 2", user_id: user_id_a})
    Accounts.create_account(%{name: "User B Account 1", user_id: user_id_b})

    user_a_accounts = Accounts.list_accounts_for_user(user_id_a)
    assert length(user_a_accounts) == 2
    assert Enum.all?(user_a_accounts, &(&1.user_id == user_id_a))

    user_b_accounts = Accounts.list_accounts_for_user(user_id_b)
    assert length(user_b_accounts) == 1
    assert Enum.all?(user_b_accounts, &(&1.user_id == user_id_b))
  end

  test "get_account_by_user/2 returns account for specific user" do
    user_id = ObjectId.generate()
    {:ok, account} = Accounts.create_account(%{name: "User Account", user_id: user_id})

    fetched_account = Accounts.get_account_by_user(account.id, user_id)
    assert fetched_account.id == account.id
    assert fetched_account.user_id == user_id

    # Test for wrong user_id
    assert is_nil(Accounts.get_account_by_user(account.id, ObjectId.generate()))
  end
end
