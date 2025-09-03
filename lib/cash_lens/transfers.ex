defmodule CashLens.Transfers do
  @moduledoc """
  The Transfers context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Transfers.Transfer

  @doc """
  Returns the list of transfers.

  ## Examples

      iex> list_transfers()
      [%Transfer{}, ...]

  """
  def list_transfers do
    Repo.all(Transfer)
    |> Repo.preload(from: [:account], to: [:account])
  end

  @doc """
  Gets a single transfer.

  Raises `Ecto.NoResultsError` if the Transfer does not exist.

  ## Examples

      iex> get_transfer!(123)
      %Transfer{}

      iex> get_transfer!(456)
      ** (Ecto.NoResultsError)

  """
  def get_transfer!(id) do
    Repo.get!(Transfer, id)
    |> Repo.preload([:from, :to])
  end

  @doc """
  Creates a transfer.

  ## Examples

      iex> create_transfer(%{field: value})
      {:ok, %Transfer{}}

      iex> create_transfer(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_transfer(attrs \\ %{}) do
    %Transfer{}
    |> Transfer.changeset(attrs)
    |> Repo.insert()
  end

  def create_transfer_from_transaction(transaction) do
    attrs =
      if transaction.amount > 0 do
        %{to_id: transaction.id}
      else
        %{from_id: transaction.id}
      end

    %Transfer{}
    |> Transfer.changeset(attrs)
    |> Repo.insert()
  end

  def update_transfer_from_transaction(from_transaction, to_transaction) do
    transfer =
      from(t in Transfer,
        where: t.from_id == ^from_transaction.id or t.to_id == ^to_transaction.id
      )
      |> Repo.one()

    update_transfer(transfer, %{
      from_id: from_transaction.id,
      to_id: to_transaction.id
    })
  end

  @doc """
  Updates a transfer.

  ## Examples

      iex> update_transfer(transfer, %{field: new_value})
      {:ok, %Transfer{}}

      iex> update_transfer(transfer, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_transfer(%Transfer{} = transfer, attrs) do
    transfer
    |> Transfer.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a transfer.

  ## Examples

      iex> delete_transfer(transfer)
      {:ok, %Transfer{}}

      iex> delete_transfer(transfer)
      {:error, %Ecto.Changeset{}}

  """
  def delete_transfer(%Transfer{} = transfer) do
    Repo.delete(transfer)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking transfer changes.

  ## Examples

      iex> change_transfer(transfer)
      %Ecto.Changeset{data: %Transfer{}}

  """
  def change_transfer(%Transfer{} = transfer, attrs \\ %{}) do
    Transfer.changeset(transfer, attrs)
  end
end
