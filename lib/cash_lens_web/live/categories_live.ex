defmodule CashLensWeb.CategoriesLive do
  use CashLensWeb, :live_view

  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.Utils

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       current_user: session["current_user"],
       current_path: "/categories",
       categories: Categories.list_categories(),
       page_title: "Categories",
       category_changeset: nil,
       editing_category: nil,
       show_form: false,
       available_types: Utils.to_options(Category.available_types()),
       available_categories: [
         {"Select a category", nil}
         | Categories.list_categories()
           |> Enum.map(fn cat -> {cat.name, cat.id} end)
       ]
     )}
  end

  def handle_event("new_category", _params, socket) do
    {:noreply,
     socket
     |> assign(
       category_changeset:
         to_form(Categories.change_category(%Category{}, %{parent_id: nil})),
       editing_category: nil,
       show_form: true
     )}
  end

  def handle_event("validate", %{"category" => category_params}, socket) do
    changeset =
      (socket.assigns.editing_category || %Category{})
      |> Categories.change_category(category_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, category_changeset: changeset)}
  end

  def handle_event("save", %{"category" => category_params}, socket) do
    if socket.assigns.editing_category do
      update_category(socket, socket.assigns.editing_category, category_params)
    else
      create_category(socket, category_params)
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    category = Categories.get_category!(id)

    {:noreply,
     socket
     |> assign(
       category_changeset: Categories.change_category(category),
       editing_category: category,
       show_form: true
     )}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, show_form: false)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    category = Categories.get_category!(id)
    {:ok, _} = Categories.delete_category(category)

    {:noreply,
     socket
     |> put_flash(:info, "Category deleted successfully.")
     |> assign(categories: Categories.list_categories())}
  end

  defp create_category(socket, category_params) do
    case Categories.create_category(category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created successfully.")
         |> assign(
           categories: Categories.list_categories(),
           show_form: false
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, category_changeset: changeset)}
    end
  end

  defp update_category(socket, category, category_params) do
    case Categories.update_category(category, category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category updated successfully.")
         |> assign(
           categories: Categories.list_categories(),
           editing_category: nil,
           show_form: false
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, category_changeset: changeset)}
    end
  end

  def render(assigns) do
    CashLensWeb.CategoriesLiveHTML.categories(assigns)
  end
end
