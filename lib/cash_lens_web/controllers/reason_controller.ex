defmodule CashLensWeb.ReasonController do
  use CashLensWeb, :controller

  alias CashLens.Reasons
  alias CashLens.Reasons.Reason
  alias CashLens.Categories

  def index(conn, _params) do
    reasons = Reasons.list_reasons() |> CashLens.Repo.preload([:category, :parent])
    render(conn, :index, reasons: reasons)
  end

  def new(conn, _params) do
    changeset = Reasons.change_reason(%Reason{})
    categories = Categories.list_categories()
    parent_reasons = Reasons.list_reasons()
    render(conn, :new, changeset: changeset, categories: categories, parent_reasons: parent_reasons)
  end

  def create(conn, %{"reason" => reason_params}) do
    case Reasons.create_reason(reason_params) do
      {:ok, reason} ->
        conn
        |> put_flash(:info, "Reason '#{to_str(reason)}' created successfully.")
        |> redirect(to: ~p"/reasons")

      {:error, %Ecto.Changeset{} = changeset} ->
        categories = Categories.list_categories()
        parent_reasons = Reasons.list_reasons()
        render(conn, :new, changeset: changeset, categories: categories, parent_reasons: parent_reasons)
    end
  end

  def show(conn, %{"id" => id}) do
    reason = Reasons.get_reason!(id) |> CashLens.Repo.preload([:category, :parent])
    render(conn, :show, reason: reason)
  end

  def edit(conn, %{"id" => id}) do
    reason = Reasons.get_reason!(id) |> CashLens.Repo.preload([:category, :parent])
    changeset = Reasons.change_reason(reason)
    categories = Categories.list_categories()
    parent_reasons = Reasons.list_reasons() |> Enum.filter(fn r -> r.id != reason.id end)
    render(conn, :edit, reason: reason, changeset: changeset, categories: categories, parent_reasons: parent_reasons)
  end

  def update(conn, %{"id" => id, "reason" => reason_params}) do
    reason = Reasons.get_reason!(id) |> CashLens.Repo.preload([:category, :parent])

    case Reasons.update_reason(reason, reason_params) do
      {:ok, reason} ->
        conn
        |> put_flash(:info, "Reason '#{to_str(reason)}' updated successfully.")
        |> redirect(to: ~p"/reasons")

      {:error, %Ecto.Changeset{} = changeset} ->
        categories = Categories.list_categories()
        parent_reasons = Reasons.list_reasons() |> Enum.filter(fn r -> r.id != reason.id end)
        render(conn, :edit, reason: reason, changeset: changeset, categories: categories, parent_reasons: parent_reasons)
    end
  end

  def delete(conn, %{"id" => id}) do
    reason = Reasons.get_reason!(id) |> CashLens.Repo.preload([:category, :parent])
    {:ok, _reason} = Reasons.delete_reason(reason)

    conn
    |> put_flash(:info, "Reason '#{to_str(reason)}' deleted successfully.")
    |> redirect(to: ~p"/reasons")
  end

  def to_str(reason) do
    "#{reason.reason}"
  end
end
