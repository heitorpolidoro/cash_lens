defmodule CashLens.Pluggy do
  @moduledoc """
  Registered Pluggy items (Open Finance connections) and the mapping between
  each Pluggy account inside an item and an existing cash_lens account.
  """
  import Ecto.Query

  alias CashLens.Pluggy.AccountLink
  alias CashLens.Pluggy.Item
  alias CashLens.Repo

  def create_item(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert()
  end

  def list_items do
    Repo.all(Item)
  end

  def get_item!(id), do: Repo.get!(Item, id)

  @doc """
  Creates a link for `pluggy_account_id` under `item` if none exists yet
  (with `account_id` left nil for the user to fill in), or updates the
  existing link's name/type without touching a already-chosen `account_id`.
  """
  def upsert_account_link(%Item{} = item, attrs) do
    pluggy_account_id = Map.fetch!(attrs, :pluggy_account_id)

    case Repo.get_by(AccountLink,
           pluggy_item_id: item.id,
           pluggy_account_id: pluggy_account_id
         ) do
      nil ->
        %AccountLink{}
        |> AccountLink.changeset(Map.put(attrs, :pluggy_item_id, item.id))
        |> Repo.insert()

      existing ->
        existing
        |> AccountLink.changeset(Map.take(attrs, [:pluggy_account_name, :pluggy_account_type]))
        |> Repo.update()
    end
  end

  def list_account_links_for_item(item_id) do
    from(l in AccountLink, where: l.pluggy_item_id == ^item_id)
    |> Repo.all()
  end

  def link_account(%AccountLink{} = account_link, account_id) do
    account_link
    |> AccountLink.changeset(%{account_id: account_id})
    |> Repo.update()
  end

  @doc """
  Links with an `account_id` already chosen — these are the ones
  `CashLens.Pluggy.Sync` imports transactions for.
  """
  def list_linked_account_links do
    from(l in AccountLink, where: not is_nil(l.account_id))
    |> Repo.all()
    |> Repo.preload([:account, :pluggy_item])
  end

  def touch_last_synced_at(%AccountLink{} = account_link) do
    account_link
    |> AccountLink.changeset(%{last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end
end
