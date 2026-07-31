defmodule CashLens.PluggyTest do
  use CashLens.DataCase, async: true

  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy
  alias CashLens.Pluggy.AccountLink

  describe "create_item/1" do
    test "creates an item with an item_id and label" do
      assert {:ok, item} = Pluggy.create_item(%{item_id: "abc-123", label: "Open Finance BB"})
      assert item.item_id == "abc-123"
      assert item.label == "Open Finance BB"
    end

    test "requires item_id" do
      assert {:error, changeset} = Pluggy.create_item(%{label: "no item_id"})
      assert "can't be blank" in errors_on(changeset).item_id
    end
  end

  describe "list_items/0" do
    test "returns all registered items" do
      item = pluggy_item_fixture()
      assert Pluggy.list_items() |> Enum.map(& &1.id) == [item.id]
    end
  end

  describe "upsert_account_link/2" do
    test "creates a new link with account_id nil when none exists" do
      item = pluggy_item_fixture()

      assert {:ok, link} =
               Pluggy.upsert_account_link(item, %{
                 pluggy_account_id: "acc-1",
                 pluggy_account_name: "BANCO DO BRASIL S/A",
                 pluggy_account_type: "BANK"
               })

      assert link.pluggy_item_id == item.id
      assert link.pluggy_account_id == "acc-1"
      assert is_nil(link.account_id)
    end

    test "updates name/type of an existing link without touching account_id" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Old Name",
          pluggy_account_type: "BANK"
        })

      {:ok, linked} = Pluggy.link_account(link, account.id)

      assert {:ok, updated} =
               Pluggy.upsert_account_link(item, %{
                 pluggy_account_id: "acc-1",
                 pluggy_account_name: "New Name",
                 pluggy_account_type: "BANK"
               })

      assert updated.id == linked.id
      assert updated.pluggy_account_name == "New Name"
      assert updated.account_id == account.id
    end
  end

  describe "list_account_links_for_item/1" do
    test "returns only links for the given item" do
      item_a = pluggy_item_fixture()
      item_b = pluggy_item_fixture()

      {:ok, link_a} =
        Pluggy.upsert_account_link(item_a, %{
          pluggy_account_id: "a1",
          pluggy_account_name: "A",
          pluggy_account_type: "BANK"
        })

      {:ok, _link_b} =
        Pluggy.upsert_account_link(item_b, %{
          pluggy_account_id: "b1",
          pluggy_account_name: "B",
          pluggy_account_type: "BANK"
        })

      assert Pluggy.list_account_links_for_item(item_a.id) |> Enum.map(& &1.id) == [link_a.id]
    end
  end

  describe "link_account/2" do
    test "sets the account_id on the link" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      assert {:ok, updated} = Pluggy.link_account(link, account.id)
      assert updated.account_id == account.id
    end
  end

  describe "list_linked_account_links/0" do
    test "returns only links that have an account_id" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, unlinked} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "unlinked",
          pluggy_account_name: "Unlinked",
          pluggy_account_type: "BANK"
        })

      {:ok, linked} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "linked",
          pluggy_account_name: "Linked",
          pluggy_account_type: "BANK"
        })

      {:ok, linked} = Pluggy.link_account(linked, account.id)

      result_ids = Pluggy.list_linked_account_links() |> Enum.map(& &1.id)
      refute unlinked.id in result_ids
      assert linked.id in result_ids
    end

    test "preloads :account and :pluggy_item" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "linked",
          pluggy_account_name: "Linked",
          pluggy_account_type: "BANK"
        })

      {:ok, _} = Pluggy.link_account(link, account.id)

      [result] = Pluggy.list_linked_account_links()
      assert %CashLens.Accounts.Account{} = result.account
      assert %CashLens.Pluggy.Item{} = result.pluggy_item
    end
  end

  describe "touch_last_synced_at/1" do
    test "sets last_synced_at to now" do
      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      assert is_nil(link.last_synced_at)
      assert {:ok, updated} = Pluggy.touch_last_synced_at(link)
      assert %DateTime{} = updated.last_synced_at
      assert DateTime.diff(DateTime.utc_now(), updated.last_synced_at, :second) < 5
    end
  end

  describe "unique index on (pluggy_item_id, pluggy_account_id)" do
    test "upsert_account_link never creates a duplicate row for the same pair" do
      item = pluggy_item_fixture()

      {:ok, first} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "First",
          pluggy_account_type: "BANK"
        })

      {:ok, second} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Second",
          pluggy_account_type: "BANK"
        })

      assert first.id == second.id
      assert length(Pluggy.list_account_links_for_item(item.id)) == 1
    end
  end
end
