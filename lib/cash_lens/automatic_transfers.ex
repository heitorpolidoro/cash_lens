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

  def create_automatic_transfer_from_transaction(transaction) do
    attrs =
      if Decimal.gt?(transaction.amount, 0) do
        %{to_id: transaction.id}
      else
        %{from_id: transaction.id}
      end

    %AutomaticTransfer{}
    |> AutomaticTransfer.changeset(attrs)
    |> Repo.insert()
  end

  def update_automatic_transfer_from_transaction(from_transaction, to_transaction) do
    if Decimal.gt?(from_transaction.amount, 0) do
      _update_automatic_transfer_from_transaction(to_transaction, from_transaction)
    else
      _update_automatic_transfer_from_transaction(from_transaction, to_transaction)
    end
  end

  defp _update_automatic_transfer_from_transaction(from_transaction, to_transaction) do
    automatic_transfer =
      from(t in AutomaticTransfer,
        where: t.from_id == ^from_transaction.id or t.to_id == ^to_transaction.id
      )
      |> Repo.one()

    update_automatic_transfer(automatic_transfer, %{
      from_id: from_transaction.id,
      to_id: to_transaction.id
    })
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
