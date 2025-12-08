defmodule CashLens.StringHelper do
  @moduledoc """
  String utility helpers for normalization and formatting.
  """

  @doc """
  Remove diacritics/accents from a binary string using Unicode NFD normalization.

  Examples:
    iex> CashLens.StringHelper.normalize_no_accents("ação")
    "acao"
  """
  @spec normalize_no_accents(binary) :: binary
  def normalize_no_accents(str) when is_binary(str) do
    str
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  @doc """
  Convert a string to title case by capitalizing the first letter of each word
  and lowercasing the rest. Words are considered to be separated by whitespace.

  Examples:
    iex> CashLens.StringHelper.to_tittle("m REIS varais e util")
    "M Reis Varais E Util"
  """
  @spec to_tittle(binary) :: binary
  def to_tittle(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/_/, " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  def to_tittle(str), do: str
end
