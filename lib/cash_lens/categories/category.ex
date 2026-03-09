defmodule CashLens.Categories.Category do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "categories" do
    field :name, :string
    field :slug, :string
    field :keywords, :string
    field :default_reimbursable, :boolean, default: false
    belongs_to :parent, CashLens.Categories.Category
    has_many :children, CashLens.Categories.Category, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :parent_id, :keywords, :default_reimbursable])
    |> validate_required([:name])
    |> generate_slug()
    |> unique_constraint(:slug)
  end

  defp generate_slug(changeset) do
    if name = get_change(changeset, :name) do
      # Base slug from current name
      base_slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-") |> String.trim("-")
      
      # Try to find parent slug
      parent_id = get_field(changeset, :parent_id)
      
      final_slug = if parent_id do
        parent = CashLens.Repo.get!(CashLens.Categories.Category, parent_id)
        "#{parent.slug}-#{base_slug}"
      else
        base_slug
      end

      put_change(changeset, :slug, final_slug)
    else
      changeset
    end
  end

  @doc """
  Returns a display name in the format 'Parent > Child'
  """
  def full_name(%__MODULE__{name: name, parent: %__MODULE__{name: parent_name}}), do: "#{parent_name} > #{name}"
  def full_name(%__MODULE__{name: name}), do: name
  def full_name(_), do: ""
end
