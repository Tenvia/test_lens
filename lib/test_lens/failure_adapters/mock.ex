defmodule TestLens.FailureAdapters.Mock do
  @moduledoc "Classifies mock / test-double failures (Mox, Mimic, etc.)."

  @mock_modules [
    "Mox.UnexpectedCallError",
    "Mox.VerificationError",
    "Mox.UnexpectedExpectationError",
    "Mimic.UnexpectedCallError",
    "Mimic.AssertionError"
  ]

  def match?({_kind, %{__exception__: true, __struct__: struct}, _stacktrace}) do
    mod = to_string(struct)
    Enum.any?(@mock_modules, &String.contains?(mod, &1))
  end

  def match?(_), do: false

  def details do
    %{
      type: :mock,
      likely_layer: "Test double / boundary",
      plain_english:
        "A mock or test double likely received an unexpected call, or an expectation was not met.",
      common_causes: [
        "changed call signature",
        "missing or stale expect/expect_call setup",
        "extra call beyond expectation",
        "stub not configured for this call"
      ],
      suggested_checks: [
        "inspect the mock setup in the test",
        "check the call signature in production code",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end
