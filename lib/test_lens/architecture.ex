defmodule TestLens.Architecture do
  @moduledoc """
  The TestLens **architecture advisor** — runs a small set of
  evidence-based OTP architecture rules against the project's topology
  and call graph (from `TestLens.OTPTopology`) and returns findings.

  Each rule is a small module under `TestLens.Architecture.Rules.<Name>`
  that exports `run/2`. The orchestrator here runs them in order and
  returns a flat list of `%TestLens.Architecture.Finding{}` records.

  Findings carry:

    * `id` — deterministic SHA-256 prefix of `(rule_id, location_key)`.
    * `rule_id` — short atom (`:cross_tree_call`, `:raw_process_spawn`, ...).
    * `severity` — `:info | :warn | :error`.
    * `confidence` — float `0.0..1.0` (rough heuristic, never claims certainty).
    * `location` — `%{file: Path.t() | nil, line: non_neg_integer() | nil}`.
    * `evidence` — short human-readable description of what matched.
    * `explanation` — one-sentence hedged description.
    * `remediation` — one-sentence suggested next step.
    * `related_modules` — list of `module()` atoms to help navigation.

  ## Limits

  v4.0 ships with **6 rules**. Each is conservative — when in doubt,
  prefer low false positives over completeness. Rule confidence is a
  rough heuristic; consumers should treat `confidence < 0.7` as
  "needs human review" rather than a hard signal.

  Rules never raise. Any failure in a rule is captured and surfaced as
  an internal finding with `:rule_error` rule_id.
  """

  alias TestLens.Architecture.Finding
  alias TestLens.OTPTopology

  @builtin_rules [
    TestLens.Architecture.Rules.CrossTreeCall,
    TestLens.Architecture.Rules.UnboundedMailbox,
    TestLens.Architecture.Rules.MismatchedRestartStrategy,
    TestLens.Architecture.Rules.RawProcessSpawn,
    TestLens.Architecture.Rules.RegistryNaming,
    TestLens.Architecture.Rules.SupervisorNoChildren
  ]

  @doc """
  Returns the list of built-in rule modules.
  """
  @spec builtin_rules() :: [module()]
  def builtin_rules, do: @builtin_rules

  @doc """
  Run every built-in rule against the given topology.

  `lib_root` is the project's `lib/` directory, used by rules that
  parse source files (e.g. `RawProcessSpawn`). When `nil`, source-based
  rules are skipped.

  Always returns a list. Never raises.
  """
  @spec run(OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%OTPTopology{} = topology, lib_root \\ nil) do
    Enum.flat_map(@builtin_rules, fn rule ->
      try do
        rule.run(topology, lib_root)
      rescue
        e ->
          [
            %Finding{
              id: rule_error_id(rule, e),
              rule_id: :rule_error,
              severity: :info,
              confidence: 1.0,
              location: %{file: nil, line: nil},
              evidence: "rule #{inspect(rule)} raised: #{Exception.message(e)}",
              explanation:
                "Internal: this rule could not run cleanly. The other rules still apply.",
              remediation: "Open an issue with the rule name and the message above.",
              related_modules: []
            }
          ]
      catch
        kind, reason ->
          [
            %Finding{
              id: rule_error_id(rule, {kind, reason}),
              rule_id: :rule_error,
              severity: :info,
              confidence: 1.0,
              location: %{file: nil, line: nil},
              evidence: "rule #{inspect(rule)} threw #{inspect(kind)}: #{inspect(reason)}",
              explanation:
                "Internal: this rule could not run cleanly. The other rules still apply.",
              remediation: "Open an issue with the rule name and the catch info above.",
              related_modules: []
            }
          ]
      end
    end)
  end

  defp rule_error_id(rule, info) do
    raw = "#{inspect(rule)}-#{inspect(info)}"
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end
end
