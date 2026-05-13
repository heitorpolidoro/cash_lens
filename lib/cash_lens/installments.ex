defmodule CashLens.Installments do
  @moduledoc """
  The Installments context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of installment groups.
  """
  def list_installment_groups do
    Repo.all(from g in InstallmentGroup, order_by: [desc: g.inserted_at])
  end

  @doc """
  Gets a single installment group.
  """
  def get_installment_group!(id), do: Repo.get!(InstallmentGroup, id)

  @doc """
  Creates an installment group.
  """
  def create_installment_group(attrs \\ %{}) do
    %InstallmentGroup{}
    |> InstallmentGroup.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an installment group.
  """
  def update_installment_group(%InstallmentGroup{} = group, attrs) do
    group
    |> InstallmentGroup.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an installment group.
  """
  def delete_installment_group(%InstallmentGroup{} = group) do
    Repo.delete(group)
  end

  @doc """
  Returns a group with its calculated progress.
  """
  def get_group_with_progress(group_id) do
    group = get_installment_group!(group_id)

    paid_count =
      Repo.aggregate(
        from(t in Transaction, where: t.installment_group_id == ^group.id),
        :count
      )

    Map.merge(group, %{
      paid_count: paid_count,
      remaining_count: max(0, group.installments - paid_count),
      is_completed: paid_count >= group.installments
    })
  end

  @doc """
  Returns all active (non-completed) installment groups.
  """
  def list_active_groups do
    groups = list_installment_groups()

    # Simple in-memory filtering for now; can be optimized with SQL if needed.
    Enum.filter(groups, fn g ->
      progress = get_group_with_progress(g.id)
      !progress.is_completed
    end)
  end

  @doc """
  Finds a matching installment group for a given description.
  """
  def find_matching_group(nil), do: nil

  def find_matching_group(description) when is_binary(description) do
    desc = String.downcase(description)

    # We look for groups whose description_pattern is contained in the transaction description.
    # Case-insensitive.
    Repo.one(
      from g in InstallmentGroup,
        where: fragment("? ILIKE '%' || ? || '%'", ^desc, g.description_pattern),
        limit: 1
    )
  end
end
