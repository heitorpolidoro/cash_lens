defmodule CashLens.AutomaticTransfers do
  @moduledoc """
  The AutomaticTransfers context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.AutomaticTransfers.AutomaticTransfer

  @doc """
  Returns the list of automatic_transfers.

  ## Examples

      iex> list_automatic_transfers()
      [%AutomaticTransfer{}, ...]

  """
  def list_automatic_transfers do
    Repo.all(AutomaticTransfer)
    |> Repo.preload([:from, :to])
  end

  @doc """
  Gets a single automatic_transfer.

  Raises `Ecto.NoResultsError` if the AutomaticTransfer does not exist.

  ## Examples

      iex> get_automatic_transfer!(123)
      %AutomaticTransfer{}

      iex> get_automatic_transfer!(456)
      ** (Ecto.NoResultsError)

  """
  def get_automatic_transfer!(id) do
    Repo.get!(AutomaticTransfer, id)
    |> Repo.preload([:from, :to])
  end

  def find_automatic_transfer_by_account!(account) do
    case Repo.one(
           from(at in AutomaticTransfer,
             where: at.from_id == ^account.id or at.to_id == ^account.id
           )
         ) do
      nil -> nil
      automatic_transfer -> Repo.preload(automatic_transfer, [:from, :to])
    end
  end

  def find_automatic_transfer_account_to!(account_from) do
    case find_automatic_transfer_by_account!(account_from) do
      nil ->
        nil

      automatic_transfer ->
        if automatic_transfer.from_id == account_from.id,
          do: automatic_transfer.to,
          else: automatic_transfer.from
    end
  end

  @doc """
  Creates a automatic_transfer.

  ## Examples

      iex> create_automatic_transfer(%{field: value})
      {:ok, %AutomaticTransfer{}}

      iex> create_automatic_transfer(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_automatic_transfer(attrs \\ %{}) do
    %AutomaticTransfer{}
    |> AutomaticTransfer.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a automatic_transfer.

  ## Examples

      iex> update_automatic_transfer(automatic_transfer, %{field: new_value})
      {:ok, %AutomaticTransfer{}}

      iex> update_automatic_transfer(automatic_transfer, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_automatic_transfer(%AutomaticTransfer{} = automatic_transfer, attrs) do
    automatic_transfer
    |> AutomaticTransfer.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a automatic_transfer.

  ## Examples

      iex> delete_automatic_transfer(automatic_transfer)
      {:ok, %AutomaticTransfer{}}

      iex> delete_automatic_transfer(automatic_transfer)
      {:error, %Ecto.Changeset{}}

  """
  def delete_automatic_transfer(%AutomaticTransfer{} = automatic_transfer) do
    Repo.delete(automatic_transfer)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking automatic_transfer changes.

  ## Examples

      iex> change_automatic_transfer(automatic_transfer)
      %Ecto.Changeset{data: %AutomaticTransfer{}}

  """
  def change_automatic_transfer(%AutomaticTransfer{} = automatic_transfer, attrs \\ %{}) do
    AutomaticTransfer.changeset(automatic_transfer, attrs)
  end
end
