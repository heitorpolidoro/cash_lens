defmodule CashLens.Reasons do
  @moduledoc """
  The Reasons context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Reasons.Reason

  @doc """
  Returns the list of reasons.

  ## Examples

      iex> list_reasons()
      [%Reason{}, ...]

  """
  def list_reasons do
    Repo.all(Reason)
  end

  @doc """
  Gets a single reason.

  Raises `Ecto.NoResultsError` if the Reason does not exist.

  ## Examples

      iex> get_reason!(123)
      %Reason{}

      iex> get_reason!(456)
      ** (Ecto.NoResultsError)

  """
  def get_reason!(id), do: Repo.get!(Reason, id)

  @doc """
  Creates a reason.

  ## Examples

      iex> create_reason(%{field: value})
      {:ok, %Reason{}}

      iex> create_reason(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_reason(attrs \\ %{}) do
    %Reason{}
    |> Reason.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a reason.

  ## Examples

      iex> update_reason(reason, %{field: new_value})
      {:ok, %Reason{}}

      iex> update_reason(reason, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_reason(%Reason{} = reason, attrs) do
    reason
    |> Reason.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a reason.

  ## Examples

      iex> delete_reason(reason)
      {:ok, %Reason{}}

      iex> delete_reason(reason)
      {:error, %Ecto.Changeset{}}

  """
  def delete_reason(%Reason{} = reason) do
    Repo.delete(reason)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking reason changes.

  ## Examples

      iex> change_reason(reason)
      %Ecto.Changeset{data: %Reason{}}

  """
  def change_reason(%Reason{} = reason, attrs \\ %{}) do
    Reason.changeset(reason, attrs)
  end

  def should_ignore_reason(reason_text) do
    from(r in Reason, where: r.reason == ^reason_text and r.ignore == true)
    |> Repo.one()
  end

  def to_str(%Reason{} = reason) do
    reason.reason
  end
end
