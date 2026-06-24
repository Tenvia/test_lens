defmodule TestLens.FailureAdapters.Unknown do
  @moduledoc "Fallback classifier for failures that did not match any known adapter."

  # Intentionally permissive: this adapter always matches so the
  # Classifier has a non-nil return value for any input.
  def match?(_failure), do: true

  def details do
    %{
      type: :unknown,
      likely_layer: "Unknown",
      plain_english: "An error we have not classified yet.",
      common_causes: [
        "library-specific error not in our classifier",
        "custom exception in this codebase",
        "infrastructure error"
      ],
      suggested_checks: [
        "inspect the error and stacktrace",
        "search the codebase for the error class",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end