defmodule TestLens.FailureAdapters.CaseClause do
  @moduledoc "Classifies CaseClauseError failures."

  def match?({:error, %CaseClauseError{}, _stacktrace}), do: true
  def match?(_), do: false

  def details do
    %{
      type: :case_clause,
      likely_layer: "Pattern match / branch coverage",
      plain_english: "A case expression likely had no clause for the given value.",
      common_causes: [
        "new enum value not handled",
        "missing case branch",
        "upstream contract drift"
      ],
      suggested_checks: [
        "inspect the value being matched",
        "inspect the case clauses",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end