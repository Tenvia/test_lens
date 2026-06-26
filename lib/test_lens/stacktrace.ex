defmodule TestLens.Stacktrace do
  @moduledoc """
  Stacktrace normalization for the agent repair artifact.

  Splits a raw ExUnit failure stacktrace (a list of MFA tuples, possibly
  with location metadata) into three lists:

    * `:app`       — frames inside the consumer's project (heuristic: not
                     under `deps/`, not under Elixir's `:elixir` modules,
                     not under `mix/` or `_build/`).
    * `:framework` — frames under Elixir/OTP standard library modules
                     (`Elixir.*` stdlib paths).
    * `:deps`      — frames under the consumer's `deps/` directory.

  Returns a `TestLens.Stacktrace.split/1` shape suitable for the agent
  artifact:

      %{
        "app"       => [%{"module" => ..., "function" => ..., "arity" => ..., "file" => ..., "line" => ...}, ...],
        "framework" => [...],
        "deps"      => [...]
      }

  Empty stacktraces return three empty lists. Frames whose module/file
  cannot be classified fall into `:app` by default (the consumer is the
  most likely owner).
  """

  @doc """
  Split a raw stacktrace (list of MFA tuples, possibly with location)
  into `app` / `framework` / `deps` frames. Returns a map with string
  keys ready for JSON encoding.
  """
  @spec split(list() | nil) :: %{required(String.t()) => list(map())}
  def split(nil), do: empty()
  def split([]), do: empty()

  def split(frames) when is_list(frames) do
    frames
    |> do_split(empty())
    |> reverse_buckets()
  end

  @doc """
  Return the top application stack frame (most recent `app` frame).
  Returns `nil` when there are no app frames.
  """
  @spec top_app_frame(list() | nil) :: map() | nil
  def top_app_frame(nil), do: nil
  def top_app_frame([]), do: nil

  def top_app_frame(frames) when is_list(frames) do
    frames
    |> Enum.find(&app_frame?/1)
    |> normalize_frame()
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp empty, do: %{"app" => [], "framework" => [], "deps" => []}

  defp do_split([], acc), do: acc

  defp do_split([frame | rest], acc) do
    bucket = classify_frame(frame)
    acc = Map.update!(acc, bucket, &[normalize_frame(frame) | &1])
    do_split(rest, acc)
  end

  # Reverse each bucket so frames appear in the original stack order
  # (call-site first, root last). We accumulate head-first to keep the
  # classifier a one-pass fold, then flip.
  defp reverse_buckets(acc) do
    Map.new(acc, fn {bucket, frames} -> {bucket, Enum.reverse(frames)} end)
  end

  # Classify a frame by its module/file. Falls back to `:app` when nothing
  # else matches (the consumer's project is the most likely owner).
  #
  # Heuristic priority:
  #   1. `file` containing `/deps/` → `:deps`.
  #   2. `module` is one of the well-known Elixir/Erlang stdlib roots →
  #      `:framework`. Whitelist because consumer modules all live under
  #      `Elixir.*` too — only the stdlib roots are recognizable without
  #      a file path.
  #   3. `file` containing `/lib/` or `/test/` → `:app` (consumer code).
  #   4. `file` containing `/_build/` → `:framework` (compiled BEAM
  #      stdlib artifacts).
  #   5. Otherwise → `:app`.
  @stdlib_prefixes ~w(
    Elixir.Kernel Elixir.Code Elixir.IO Elixir.Logger Elixir.Process
    Elixir.System Elixir.String Elixir.List Elixir.Map Elixir.Tuple
    Elixir.Enum Elixir.Stream Elixir.Exception Elixir.Task Elixir.Agent
    Elixir.GenServer Elixir.Supervisor Elixir.Application Elixir.Node
    Elixir.Registry Elixir.Mix Elixir.Config Elixir.Path Elixir.File
    Elixir.URI Elixir.Date Elixir.Time Elixir.DateTime Elixir.Calendar
    Elixir.Enumerable Elixir.Collectable Elixir.Function Elixir.Macro
    Elixir.Module Elixir.Behaviour Elixir.Spec Elixir.DynamicSupervisor
    Elixir.StringIO Elixir.Version Elixir.System Elixir.Hex Elixir.Float
    Elixir.Integer Elixir.Atom Elixir.Bitstring Elixir.List Elixir.Port
    Elixir.Signal Elixir.Record Elixir.Set
  )

  defp classify_frame(frame) do
    file = frame_file(frame)
    module = frame_module(frame)

    cond do
      is_binary(file) and build_path?(file) ->
        "framework"

      is_binary(file) and deps_path?(file) ->
        "deps"

      is_binary(file) and (String.contains?(file, "/lib/") or String.contains?(file, "/test/")) ->
        "app"

      is_atom(module) and module != nil ->
        module_name = Atom.to_string(module)

        if stdlib?(module_name) do
          "framework"
        else
          "app"
        end

      true ->
        "app"
    end
  end

  # `_build/...` paths point at compiled BEAM stdlib / dep artifacts.
  # We accept both relative (`_build/...`) and absolute (`/_build/...`)
  # forms. Compiled deps also live under `_build/`, but those are matched
  # by deps_path? below (which checks `lib/<dep>/...` patterns).
  defp build_path?("/_build/" <> _), do: true

  defp build_path?(file) when is_binary(file) do
    String.starts_with?(file, "_build/")
  end

  defp build_path?(_), do: false

  # A "deps path" is anything rooted under a consumer `deps/` directory.
  # We accept either a leading `deps/` (relative path) or `/deps/` so
  # both forms work, plus the compiled-artifact path `_build/.../lib/`.
  defp deps_path?("/deps/" <> _), do: true

  defp deps_path?(file) when is_binary(file) do
    String.contains?(file, "/deps/") or
      String.starts_with?(file, "deps/")
  end

  defp deps_path?(_), do: false

  defp stdlib?(module_name) do
    Enum.any?(@stdlib_prefixes, &String.starts_with?(module_name, &1 <> ".")) or
      String.starts_with?(module_name, ":") or
      module_name in ["lists", "erlang", "elixir", "erts_debug", "io_lib", "string"]
  end

  defp app_frame?(frame) do
    case classify_frame(frame) do
      "app" -> true
      _ -> false
    end
  end

  defp normalize_frame(nil), do: nil

  defp normalize_frame(frame) do
    %{
      "module" => stringify(frame_module(frame)),
      "function" => stringify(frame_function(frame)),
      "arity" => frame_arity(frame),
      "file" => frame_file(frame),
      "line" => frame_line(frame)
    }
  end

  # MFA tuple shapes: {module, function, arity} or {module, function, arity, [file: ..., line: ...]}.
  defp frame_module({m, _f, _a}), do: m
  defp frame_module({m, _f, _a, _loc}), do: m
  defp frame_module(_), do: nil

  defp frame_function({_m, f, _a}), do: f
  defp frame_function({_m, f, _a, _loc}), do: f
  defp frame_function(_), do: nil

  defp frame_arity({_m, _f, a}) when is_integer(a), do: a
  defp frame_arity({_m, _f, a, _loc}) when is_integer(a), do: a
  defp frame_arity(_), do: nil

  defp frame_file({_m, _f, _a, loc}) when is_list(loc) do
    Keyword.get(loc, :file)
  end

  defp frame_file(_), do: nil

  defp frame_line({_m, _f, _a, loc}) when is_list(loc) do
    Keyword.get(loc, :line)
  end

  defp frame_line(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
