defmodule CashLens.OwnershipTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.UsersFixtures

  alias CashLens.Accounts.Account
  alias CashLens.Ownership

  describe "scope/2" do
    test "filters by the given user even when RLS shows another user's rows" do
      %{a: a, b: b} = cross_tenant()
      account_a = account_fixture(%{user: a})
      account_b = account_fixture(%{user: b})
      assert account_b.user_id == b.id

      Repo.with_user(a.id, fn ->
        assert Repo.all(Account) == [account_a]
        assert Account |> Ownership.scope(b) |> Repo.all() == []
        assert Account |> Ownership.scope(a) |> Repo.all() == [account_a]
      end)
    end

    test "builds SQL with a user_id equality bound to the user id" do
      %{b: b} = cross_tenant()
      {sql, params} = Repo.to_sql(:all, Ownership.scope(Account, b))
      assert sql =~ ~r/user_id" = \$1/
      assert params == [Ecto.UUID.dump!(b.id)]
    end

    test "keeps the existing where of a query" do
      %{b: b} = cross_tenant()
      query = from(x in Account, where: x.name == "n")
      {sql, params} = Repo.to_sql(:all, Ownership.scope(query, b))
      assert sql =~ "name"
      assert sql =~ "user_id"
      assert length(params) == 1
    end
  end

  describe "validate_owned/3" do
    setup do
      %{a: a, b: b} = cross_tenant()
      {:ok, a: a, b: b}
    end

    test "no error for an id of the same user", %{a: a} do
      account = account_fixture(%{user: a})
      cs = Ecto.Changeset.change(%Account{user_id: a.id}, %{id: account.id})
      assert Ownership.validate_owned(cs, :id, Account).errors == []
    end

    test "error for an id of another user", %{a: a, b: b} do
      other = account_fixture(%{user: b})
      cs = Ecto.Changeset.change(%Account{user_id: a.id}, %{id: other.id})
      assert [id: {"does not exist", _}] = Ownership.validate_owned(cs, :id, Account).errors
    end

    test "error for an unknown or malformed id and for a missing owner", %{a: a, b: b} do
      cs = Ecto.Changeset.change(%Account{user_id: a.id}, %{id: Ecto.UUID.generate()})
      assert Ownership.validate_owned(cs, :id, Account).errors != []
      cs = Ecto.Changeset.change(%Account{user_id: a.id}, %{id: "nope"})
      assert Ownership.validate_owned(cs, :id, Account).errors != []

      other = account_fixture(%{user: b})
      cs = Ecto.Changeset.change(%Account{}, %{id: other.id})
      assert Ownership.validate_owned(cs, :id, Account).errors != []
    end

    test "no error without a change", %{a: a} do
      cs = Ecto.Changeset.change(%Account{user_id: a.id})
      assert Ownership.validate_owned(cs, :id, Account).errors == []
    end
  end

  describe "tenancy fixtures" do
    test "account_fixture honours :user and defaults to the pinned user", ctx do
      %{b: b} = cross_tenant()
      assert account_fixture(%{user: b}).user_id == b.id
      assert account_fixture().user_id == ctx.current_user_id
      assert Repo.current_user_id() == ctx.current_user_id
    end

    @tag :no_current_user
    test "account_fixture creates a user when none is pinned" do
      assert account_fixture().user_id
    end

    test "cross_tenant returns two distinct users and supports a function" do
      %{a: a, b: b} = cross_tenant()
      assert a.id != b.id
      assert cross_tenant(fn x, y -> x.id != y.id end)
    end

    test "other domain fixtures accept :user" do
      %{b: b} = cross_tenant()
      assert CashLens.CategoriesFixtures.category_fixture(%{user: b}).user_id == b.id
      assert CashLens.AccountingFixtures.balance_fixture(%{user: b}).user_id == b.id
      assert CashLens.TransactionsFixtures.transaction_fixture(%{user: b}).user_id == b.id
      assert CashLens.TransactionsFixtures.transfer_rule_fixture(%{user: b}).user_id == b.id

      assert CashLens.TransactionsFixtures.insert_bulk_ignore_pattern(%{user: b}).user_id ==
               b.id

      assert CashLens.ForecastFixtures.recurring_item_fixture(%{user: b}).user_id == b.id
      assert CashLens.CreditCardsFixtures.statement_fixture(%{user: b}).user_id == b.id
    end
  end
end
