defmodule TestLens.Adapters.Ecto do
  @moduledoc "Ecto adapter: schemas and repos."
  @needles ["Repo", "Schema"]

  @spec category :: :ecto
  def category, do: :ecto

  @spec match?(ExUnit.Test.t()) :: boolean()
  def match?(%ExUnit.Test{module: mod, tags: tags}) when not is_nil(mod) do
    name = mod |> Atom.to_string() |> String.trim_leading("Elixir.")
    contains = Enum.any?(@needles, &String.contains?(name, &1))
    contains or Map.has_key?(tags, :ecto)
  end

  def match?(_), do: false
end