defmodule TestLens.Architecture.Rules.UnboundedMailbox do
  @moduledoc """
  Flags `GenServer.call` invocations in cross-tree edges that do not
  pass an explicit `:timeout` option. The default timeout is 5_000ms,
  which silently masks backpressure; agents and humans should at least
  name the timeout.
  """

  alias TestLens.Architecture.Finding

  @rule_id :unbounded_mailbox

  @doc """
  Run the unbounded-mailbox rule. Conservative: we only flag
  cross-tree edges where the AST node did not include a `:timeout`
  option. Source-based detection requires `lib_root`.
  """
  @spec run(TestLens.OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%TestLens.OTPTopology{} = topology, lib_root \\ nil) do
    if lib_root == nil do
      []
    else
      Enum.flat_map(topology.call_edges, fn edge ->
        if edge.kind == :call and
             TestLens.OTPTopology.cross_tree_call?(topology, edge.from, edge.to) and
             not has_timeout?(lib_root, edge.from) do
          [
            Finding.from(
              @rule_id,
              "#{edge.from}->#{edge.to}",
              {:info, 0.70},
              "GenServer.call from #{inspect(edge.from)} to #{inspect(edge.to)} does not appear to set :timeout",
              "Default 5s timeout can mask backpressure; explicit timeouts surface problems earlier.",
              "Pass `timeout: N` to the cross-tree call so failure modes are visible.",
              %{file: nil, line: nil},
              [edge.from, edge.to]
            )
          ]
        else
          []
        end
      end)
    end
  end

  defp has_timeout?(lib_root, from_module) do
    from_module
    |> file_path_for(lib_root)
    |> case do
      nil ->
        false

      path ->
        try do
          path
          |> File.read!()
          |> String.contains?("timeout:")
        rescue
          _ -> false
        end
    end
  end

  defp file_path_for(module, lib_root) do
    module
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.join("/")
    |> then(&Path.join(lib_root, &1 <> ".ex"))
    |> tap(&check/1)
  end

  defp check(path) do
    if File.regular?(path), do: path, else: nil
  end
end
