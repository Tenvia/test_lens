defmodule TestLens.FailureAdapters.MatchError do
  @moduledoc "Classifies MatchError (pattern match) failures."

  def match?({:error, %MatchError{}, _stacktrace}), do: true
  def match?(_), do: false

  def details do
    %{
      type: :match_error,
      likely_layer: "Pattern match / data shape",
      plain_english: "A pattern match likely failed because the value did not match the expected shape.",
      common_causes: [
        "an upstream return value changed shape",
        "a missing case branch",
        "a new enum / atom value not handled"
      ],
      suggested_checks: [
        "inspect the value being matched",
        "inspect the pattern",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end