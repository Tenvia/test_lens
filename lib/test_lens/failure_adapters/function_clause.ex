defmodule TestLens.FailureAdapters.FunctionClause do
  @moduledoc "Classifies FunctionClauseError failures."

  def match?({:error, %FunctionClauseError{}, _stacktrace}), do: true
  def match?(_), do: false

  def details do
    %{
      type: :function_clause,
      likely_layer: "Contract / function boundary",
      plain_english: "A function likely received data in a shape it does not handle.",
      common_causes: [
        "changed params between caller and receiver",
        "missing function head",
        "caller/receiver contract drift"
      ],
      suggested_checks: [
        "inspect the failing function head",
        "inspect the caller",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end
