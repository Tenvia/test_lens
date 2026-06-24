defmodule TestLens.FailureAdapters.EctoConstraint do
  @moduledoc "Classifies Ecto changeset/constraint-style failures."

  @ecto_modules [
    "Ecto.ConstraintError",
    "Ecto.ChangeError",
    "Ecto.NoResultsError",
    "Ecto.MultipleResultsError"
  ]

  def match?({_kind, %{__exception__: true, __struct__: struct}, _stacktrace}) do
    mod = to_string(struct)
    Enum.any?(@ecto_modules, &String.contains?(mod, &1))
  end

  def match?(_), do: false

  def details do
    %{
      type: :ecto_constraint,
      likely_layer: "Data validation / persistence",
      plain_english: "An Ecto changeset likely violated a database constraint or expected a different result.",
      common_causes: [
        "missing changeset validations",
        "stale schema definition",
        "possible race condition on a unique index",
        "fixture data missing required fields"
      ],
      suggested_checks: [
        "inspect the changeset and the failing constraint",
        "check schema validations",
        "rerun the exact file"
      ],
      default_severity: :other
    }
  end
end