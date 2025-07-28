defmodule CashLens.Helper do
  @moduledoc false

  def format_atom_title(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
  def format_atom_title(string) when is_binary(string) do
    string
    |> String.to_atom()
    |> format_atom_title()
  end

end
