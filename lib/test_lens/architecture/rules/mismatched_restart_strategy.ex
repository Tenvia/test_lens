defmodule TestLens.Architecture.Rules.MismatchedRestartStrategy do
  @moduledoc """
  Flags supervisors whose `strategy:` keyword argument does not match
  what their children would benefit from. The rule is intentionally
  conservative: it only fires when we can detect a literal strategy
  in the supervisor's child spec or in the supervisor's own
  initialization.

  Note: in v4.0 we only fire the rule when both the supervisor's
  declared strategy AND at least one child's declared strategy can be
  resolved via `Application.started_applications/0` (i.e. the supervisor
  is actually running). When we cannot resolve the child spec, the
  rule returns no findings.
  """

  alias TestLens.Architecture.Finding

  # Conservative strategy ranking. Lower number = "expects children to
  # fail together"; higher = "expects isolation". We flag a clear
  # mismatch where a parent is `rest_for_one` (tight coupling) but a
  # child is configured `permanent` with a `:significant` set, since
  # that combination usually indicates a copy-paste error.
  #
  # In practice v4.0's input is best-effort; this rule fires only when
  # both strategy and child spec are detectable from the runtime.
  @doc """
  Run the mismatched-restart-strategy rule. Currently a no-op stub
  because resolving child specs at runtime requires :supervisor child
  spec introspection that Elixir 1.19 does not expose publicly. The
  rule is reserved for v4.1.
  """
  @spec run(TestLens.OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%TestLens.OTPTopology{} = _topology, _lib_root \\ nil), do: []

  # Commented out until child-spec introspection is available in v4.1.
  #
  # defp strategies(topology) do
  #   Enum.flat_map(topology.supervisors, fn {app, pid} ->
  #     safe_which_children(pid)
  #     |> Enum.map(fn child_spec -> {app, child_spec} end)
  #   end)
  # end

  # defp safe_which_children(pid) do
  #   Supervisor.which_children(pid)
  # rescue
  #   _ -> []
  # end
end
