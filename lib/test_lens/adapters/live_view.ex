defmodule TestLens.Adapters.LiveView do
  @moduledoc "Phoenix LiveView adapter."
  @suffixes ["LiveView", "LiveComponent", "LiveViewTest", "LiveTest"]

  @spec category :: :live_view
  def category, do: :live_view

  @spec match?(ExUnit.Test.t()) :: boolean()
  def match?(%ExUnit.Test{module: mod, tags: tags}) when not is_nil(mod) do
    name = mod |> Atom.to_string() |> String.trim_leading("Elixir.")
    has_suffix = Enum.any?(@suffixes, &String.ends_with?(name, &1))
    has_suffix or Map.has_key?(tags, :live_view)
  end

  def match?(_), do: false
end