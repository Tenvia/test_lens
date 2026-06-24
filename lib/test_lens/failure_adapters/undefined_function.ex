defmodule TestLens.FailureAdapters.UndefinedFunction do
  @moduledoc "Classifies UndefinedFunctionError failures."

  def match?({:error, %UndefinedFunctionError{}, _stacktrace}), do: true
  def match?(_), do: false

  def details do
    %{
      type: :undefined_function,
      likely_layer: "Module API / dispatch",
      plain_english: "A function is likely not exported by the module being called, or the module itself is not loaded.",
      common_causes: [
        "renamed or moved function",
        "typo in the module or function name",
        "missing dependency",
        "conditional compilation pruned the function"
      ],
      suggested_checks: [
        "check the module and function name spelling",
        "check that the owning library is a dependency",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end