defmodule TestLens.FailureAdapters.Assertion do
  @moduledoc "Classifies generic ExUnit assertion failures (the catch-all for :error kind with ExUnit.AssertionError)."

  def match?({:error, %ExUnit.AssertionError{}, _stacktrace}), do: true
  def match?(_), do: false

  def details do
    %{
      type: :assertion,
      likely_layer: "Test assertion",
      plain_english: "An assertion in the test likely did not hold.",
      common_causes: [
        "expected value drifted from the test's expectation",
        "fixture or factory data not in the expected state",
        "possible race condition in setup"
      ],
      suggested_checks: [
        "inspect the assertion expression",
        "rerun the test alone",
        "check the fixture or factory data"
      ],
      default_severity: :other
    }
  end
end