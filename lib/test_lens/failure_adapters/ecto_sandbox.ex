defmodule TestLens.FailureAdapters.EctoSandbox do
  @moduledoc "Classifies Ecto SQL sandbox-style failures."

  @sandbox_modules [
    "DBConnection.ConnectionError",
    "Ecto.Adapters.SQL.Sandbox",
    "Ecto.SQL.Sandbox"
  ]

  def match?({_kind, %{__exception__: true, __struct__: struct}, _stacktrace}) do
    mod = to_string(struct)
    Enum.any?(@sandbox_modules, &String.contains?(mod, &1))
  end

  def match?(_), do: false

  def details do
    %{
      type: :ecto_sandbox,
      likely_layer: "Test isolation / database",
      plain_english: "A database operation likely ran outside the SQL sandbox, or the sandbox was not checked out for this process.",
      common_causes: [
        "missing Ecto.Adapters.SQL.Sandbox.checkout",
        "async test without sandbox ownership",
        "Task spawned without sandbox allowance",
        "ownership timed out before the test finished"
      ],
      suggested_checks: [
        "check Ecto.Adapters.SQL.Sandbox usage",
        "check for an async Task that needs :allow",
        "rerun the exact file with sandbox mode"
      ],
      default_severity: :other
    }
  end
end