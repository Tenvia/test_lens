defmodule TestLens.Fingerprint do
  @moduledoc """
  Deterministic fingerprints for ExUnit failures.

  A fingerprint is a stable identifier for a class of failure that an
  agent can use to group duplicates across runs. Two failures with the
  same fingerprint represent the same underlying root cause.

  ## What goes into the fingerprint

  - The failure `kind` (`:error`, `:exit`, `:throw`, `:invalid`).
  - The classifier `type` (`:function_clause`, `:assertion`, ...).
  - The top application stack frame (module + function + arity).
  - The test file path.

  Two failures with identical fingerprints are presumed to share a root
  cause and should be fixed together. Fingerprints are intentionally
  coarse: the goal is grouping, not identity. Per-run identity lives on
  the failure entry itself.
  """

  @doc """
  Compute a fingerprint for a failure entry map.

  Accepts a map with at least `:kind`, `:classification_type`, `:file`,
  and `:top_app_frame` keys (string forms). Returns a lowercase hex SHA-256
  digest.

  `nil` and empty-string inputs are normalized to a sentinel so that
  fingerprints remain stable when optional fields are absent.
  """
  @spec compute(map()) :: String.t()
  def compute(%{} = failure) do
    parts = [
      normalize(failure[:kind] || failure["kind"]),
      normalize(failure[:classification_type] || failure["classification_type"]),
      normalize(failure[:file] || failure["file"]),
      normalize(failure[:top_app_frame] || failure["top_app_frame"])
    ]

    :crypto.hash(:sha256, Enum.join(parts, "|"))
    |> Base.encode16(case: :lower)
  end

  defp normalize(nil), do: "_"
  defp normalize(""), do: "_"
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: to_string(value)
end
