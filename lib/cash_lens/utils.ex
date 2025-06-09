defmodule CashLens.Utils do
  @moduledoc false

  def to_normalized_atom(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[-\s]/, "_")
    |> String.to_atom()
  end

  def to_atoms(list) do
    Enum.map(list, &to_normalized_atom/1)
  end

  def capitalize(string) when is_atom(string) do
    string
    |> Atom.to_string()
    |> capitalize
  end
  def capitalize(string) do
    string
    |> String.replace("_", " ")  # Replace underscores
    |> String.split(" ")         # Split into words
    |> Enum.map(&String.capitalize/1) # Capitalize each word
    |> Enum.join(" ")
  end

  def from_atom(atom) do
    capitalize(Atom.to_string(atom))
  end

  def from_atoms(list) do
    Enum.map(list, &from_atom/1)
  end

  def to_options(list) do
    Enum.map(list, fn item -> {item, to_normalized_atom(item)} end)
  end
end
