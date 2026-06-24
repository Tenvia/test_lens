defmodule TestLens.Adapters.Phoenix do
  @moduledoc "Phoenix adapter: controllers, views, channels, routers, plugs."
  @suffixes [
    "Controller",
    "ControllerTest",
    "View",
    "ViewTest",
    "Channel",
    "ChannelTest",
    "Endpoint",
    "EndpointTest",
    "Router",
    "RouterTest",
    "Plug",
    "PlugTest"
  ]

  @spec category :: :phoenix
  def category, do: :phoenix

  @spec match?(ExUnit.Test.t()) :: boolean()
  def match?(%ExUnit.Test{module: mod, tags: tags}) when not is_nil(mod) do
    name = mod |> Atom.to_string() |> String.trim_leading("Elixir.")
    has_suffix = Enum.any?(@suffixes, &String.ends_with?(name, &1))
    has_suffix or Map.has_key?(tags, :phoenix)
  end

  def match?(_), do: false
end
