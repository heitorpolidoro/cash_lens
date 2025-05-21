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

  def to_options(list) do
    Enum.map(list, fn item -> {item, to_normalized_atom(item)} end)
  end
end
