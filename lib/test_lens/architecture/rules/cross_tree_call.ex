defmodule TestLens.Architecture.Rules.CrossTreeCall do
  @moduledoc """
  Flags `GenServer.call` edges whose caller and callee live in
  different supervision subtrees. These calls couple two otherwise
  independent restart domains: a crash or backpressure in one tree
  can stall the other.
  """

  alias TestLens.Architecture.Finding

  @rule_id :cross_tree_call

  @doc """
  Run the cross-tree-call rule against `topology`. The optional
  `lib_root` is currently unused (we infer cross-tree from the
  call edges + supervisor map alone) but accepted for symmetry with
  source-based rules.
  """
  @spec run(TestLens.OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%TestLens.OTPTopology{} = topology, _lib_root \\ nil) do
    Enum.flat_map(topology.call_edges, fn edge ->
      cond do
        edge.kind != :call ->
          []

        edge.to == nil ->
          []

        TestLens.OTPTopology.cross_tree_call?(topology, edge.from, edge.to) ->
          [
            Finding.from(
              @rule_id,
              "#{edge.from}->#{edge.to}",
              {:warn, 0.85},
              "GenServer.call from #{inspect(edge.from)} to #{inspect(edge.to)}",
              "These modules likely live in different supervision subtrees, so a crash or backpressure in one can stall the other.",
              "Move the call under a shared parent, use async cast, or make the call sites belong to the same supervisor.",
              %{file: nil, line: nil},
              [edge.from, edge.to]
            )
          ]

        true ->
          []
      end
    end)
  end
end
