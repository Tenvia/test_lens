defmodule TestLens.Architecture.Rules.SupervisorNoChildren do
  @moduledoc """
  Flags supervisors that declared no children at the time the
  topology was captured. Empty supervisors usually mean a forgotten
  `init/1` configuration; less commonly, they mean a deliberate
  stub for future expansion.

  Detection is best-effort: a supervisor with one of its children
  still initializing, or a supervisor that is itself a leaf of a
  dynamic supervisor, may appear "empty" transiently. Confidence is
  set low (0.50) for this rule.
  """

  alias TestLens.Architecture.Finding

  @rule_id :supervisor_no_children

  @doc """
  Run the supervisor-no-children rule. Iterates the captured
  supervisors in the topology and emits one finding per supervisor
  with zero `which_children/1` results.
  """
  @spec run(TestLens.OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%TestLens.OTPTopology{} = topology, _lib_root \\ nil) do
    Enum.flat_map(topology.supervisors, fn {app, pid} ->
      case safe_which_children(pid) do
        [] ->
          [
            Finding.from(
              @rule_id,
              Atom.to_string(app),
              {:info, 0.50},
              "Supervisor for application #{inspect(app)} has no children at topology capture time",
              "Empty supervisors are often forgotten init configurations. Confirm whether this is deliberate.",
              "If intentional, document it with a `@moduledoc` note. Otherwise, add the missing `init/1` child specs.",
              %{file: nil, line: nil},
              []
            )
          ]

        _ ->
          []
      end
    end)
  end

  defp safe_which_children(pid) do
    Supervisor.which_children(pid)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
