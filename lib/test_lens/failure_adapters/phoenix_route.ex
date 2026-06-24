defmodule TestLens.FailureAdapters.PhoenixRoute do
  @moduledoc "Classifies Phoenix controller / router / route-style failures."

  @route_modules [
    "Phoenix.Router.NoRouteError",
    "Phoenix.Router.EndpointNotFoundError",
    "Phoenix.NotFoundError",
    "Phoenix.ActionClauseError"
  ]

  def match?({_kind, %{__exception__: true, __struct__: struct}, _stacktrace}) do
    mod = to_string(struct)
    Enum.any?(@route_modules, &String.contains?(mod, &1))
  end

  def match?(_), do: false

  def details do
    %{
      type: :phoenix_route,
      likely_layer: "Routing / controller dispatch",
      plain_english: "A Phoenix route likely did not match, or a controller action could not be invoked.",
      common_causes: [
        "router changed and the test path is stale",
        "wrong HTTP verb",
        "missing or renamed route",
        "wrong param name in path helpers"
      ],
      suggested_checks: [
        "inspect the failing path and verb",
        "inspect the router",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end