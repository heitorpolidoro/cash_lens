defmodule CashLensWeb.WebUtils do
  alias CashLens.Utils

  def format_option(options, key) do
    Enum.find(options, fn value -> Utils.to_normalized_atom(value) == key end)
  end
end
