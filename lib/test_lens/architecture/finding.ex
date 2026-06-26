defmodule TestLens.Architecture.Finding do
  @moduledoc """
  A single architecture-advisor finding.

  Findings are pure data. They carry everything an agent or a human
  needs to triage the issue: where it was found, what matched, why it
  matters, what to do next, and which modules are likely affected.
  """

  @enforce_keys [
    :id,
    :rule_id,
    :severity,
    :confidence,
    :location,
    :evidence,
    :explanation,
    :remediation,
    :related_modules
  ]

  defstruct [
    :id,
    :rule_id,
    :severity,
    :confidence,
    :location,
    :evidence,
    :explanation,
    :remediation,
    related_modules: []
  ]

  @type severity :: :info | :warn | :error
  @type location :: %{file: Path.t() | nil, line: non_neg_integer() | nil}

  @type t :: %__MODULE__{
          id: String.t(),
          rule_id: atom(),
          severity: severity(),
          confidence: float(),
          location: location(),
          evidence: String.t(),
          explanation: String.t(),
          remediation: String.t(),
          related_modules: [module()]
        }

  @doc """
  Build a Finding with a deterministic id derived from the rule and
  a stable key.

  `severity_confidence` is a `{severity, confidence}` pair. This
  collapses two parameters into one to stay under Credo's max-arity
  threshold without sacrificing readability.
  """
  @spec from(
          atom(),
          String.t(),
          {severity(), float()},
          String.t(),
          String.t(),
          String.t(),
          location(),
          [module()]
        ) ::
          t()
  def from(
        rule_id,
        stable_key,
        severity_confidence,
        evidence,
        explanation,
        remediation,
        location,
        related_modules \\ []
      ) do
    {severity, confidence} = severity_confidence

    %__MODULE__{
      id: derive_id(rule_id, stable_key),
      rule_id: rule_id,
      severity: severity,
      confidence: confidence,
      location: location,
      evidence: evidence,
      explanation: explanation,
      remediation: remediation,
      related_modules: related_modules
    }
  end

  defp derive_id(rule_id, stable_key) do
    raw = "#{rule_id}-#{stable_key}"
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  @doc "Encode the finding as a JSON-friendly map (string keys, atom keys flattened)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = f) do
    %{
      "id" => f.id,
      "rule_id" => Atom.to_string(f.rule_id),
      "severity" => Atom.to_string(f.severity),
      "confidence" => f.confidence,
      "location" => f.location,
      "evidence" => f.evidence,
      "explanation" => f.explanation,
      "remediation" => f.remediation,
      "related_modules" => Enum.map(f.related_modules, &Atom.to_string/1)
    }
  end
end
