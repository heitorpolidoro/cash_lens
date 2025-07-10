defmodule CashLens.ReasonsToIgnore do
  @moduledoc """
  The Reasons_To_Ignore context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.ReasonsToIgnore.ReasonToIgnore

  @doc """
  Returns the list of reasons_to_ignore.

  ## Examples

      iex> list_reasons_to_ignore()
      [%ReasonToIgnore{}, ...]

  """
  def list_reasons_to_ignore do
    Repo.all(ReasonToIgnore)
  end

  @doc """
  Gets a single reasonToIgnore.

  Raises `Ecto.NoResultsError` if the ReasonToIgnore does not exist.

  ## Examples

      iex> get_reason_to_ignore!(123)
      %ReasonToIgnore{}

      iex> get_reason_to_ignore!(456)
      ** (Ecto.NoResultsError)

  """
  def get_reason_to_ignore!(id), do: Repo.get!(ReasonToIgnore, id)

  def get_reasons_to_ignore_by_parser!(parser) do
    ReasonToIgnore
    |> where([r], r.parser == ^parser)
    |> select([r], r.reason)
    |> Repo.all()
#    Repo.all(from r in ReasonToIgnore, where: r.parser == ^parser) |> select(:reason)
  end

  @doc """
  Creates a reasonToIgnore.

  ## Examples

      iex> create_reason_to_ignore(%{field: value})
      {:ok, %ReasonToIgnore{}}

      iex> create_reason_to_ignore(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_reason_to_ignore(attrs \\ %{}) do
    %ReasonToIgnore{}
    |> ReasonToIgnore.changeset(attrs)
    |> Repo.insert()

    {:ok, %{reason: "ok"}}
  end

  @doc """
  Updates a reasonToIgnore.

  ## Examples

      iex> update_reason_to_ignore(reasonToIgnore, %{field: new_value})
      {:ok, %ReasonToIgnore{}}

      iex> update_reason_to_ignore(reasonToIgnore, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_reason_to_ignore(%ReasonToIgnore{} = reasonToIgnore, attrs) do
    reasonToIgnore
    |> ReasonToIgnore.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a reasonToIgnore.

  ## Examples

      iex> delete_reason_to_ignore(reasonToIgnore)
      {:ok, %ReasonToIgnore{}}

      iex> delete_reason_to_ignore(reasonToIgnore)
      {:error, %Ecto.Changeset{}}

  """
  def delete_reason_to_ignore(%ReasonToIgnore{} = reasonToIgnore) do
    Repo.delete(reasonToIgnore)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking reasonToIgnore changes.

  ## Examples

      iex> change_reason_to_ignore(reasonToIgnore)
      %Ecto.Changeset{data: %ReasonToIgnore{}}

  """
  def change_reason_to_ignore(%ReasonToIgnore{} = reasonToIgnore, attrs \\ %{}) do
    ReasonToIgnore.changeset(reasonToIgnore, attrs)
  end

end
