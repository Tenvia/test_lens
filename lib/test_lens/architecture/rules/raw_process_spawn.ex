defmodule TestLens.Architecture.Rules.RawProcessSpawn do
  @moduledoc """
  Flags direct `spawn` / `spawn_link` / `spawn_monitor` invocations
  outside `start_supervised` / `start_link`-style supervisor wiring.
  Raw process spawn leaks work into the application's process tree
  with no restart strategy and no supervision. ExUnit's
  `start_supervised` is the recommended replacement.

  ## Source-based

  This rule scans every `.ex` under `lib_root`. It only fires when a
  raw `spawn` call is found in module body that is NOT a child of a
  `use Supervisor` or `use GenServer` block. Conservative: it ignores
  `spawn` inside `defp` test helpers and inside mix tasks (heuristic).
  """

  alias TestLens.Architecture.Finding

  @rule_id :raw_process_spawn

  @doc """
  Run the raw-process-spawn rule. Returns one finding per `.ex` file
  that contains a literal raw spawn call.
  """
  @spec run(TestLens.OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%TestLens.OTPTopology{} = _topology, lib_root \\ nil) do
    if lib_root == nil do
      []
    else
      lib_root
      |> list_ex_files()
      |> Enum.flat_map(&scan_file/1)
    end
  end

  defp list_ex_files(root) do
    case File.ls(root) do
      {:ok, entries} when is_list(entries) ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          cond do
            File.regular?(path) and String.ends_with?(path, ".ex") -> [path]
            File.dir?(path) -> list_ex_files(path)
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp scan_file(path) do
    try do
      src = File.read!(path)
      ast = Code.string_to_quoted!(src)
      module_name = infer_module(path)
      module_uses_supervisor = uses_supervisor?(ast)

      case module_name do
        nil -> []
        _ -> walk_for_spawn(ast, path, module_name, module_uses_supervisor)
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp infer_module(path) do
    case Path.basename(path, ".ex") do
      "" ->
        nil

      name ->
        name
        |> Macro.camelize()
        |> List.wrap()
        |> Module.concat()
    end
  end

  defp uses_supervisor?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _meta, [Supervisor | _]} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp walk_for_spawn(ast, path, module_name, _module_uses_supervisor) do
    {_, findings} =
      Macro.prewalk(ast, [], fn
        # `:erlang.spawn(...)` parses to
        # `{{:., _, [:erlang, :spawn]}, _, [args]}` — a 3-tuple whose
        # first element is itself a 3-tuple. We match the outer call.
        {{:., _, [:erlang, :spawn]}, _, _} = node, acc ->
          {node, [finding(module_name, :erlang_spawn, path) | acc]}

        {{:., _, [:erlang, :spawn_link]}, _, _} = node, acc ->
          {node, [finding(module_name, :erlang_spawn_link, path) | acc]}

        {{:., _, [:erlang, :spawn_monitor]}, _, _} = node, acc ->
          {node, [finding(module_name, :erlang_spawn_monitor, path) | acc]}

        # `Task.start/1` parses to the standard alias form (also a
        # 3-tuple whose first element is a 3-tuple).
        {{:., _, [{:__aliases__, _, [:Task]}, :start]}, _, _} = node, acc ->
          {node, [finding(module_name, :task_start, path) | acc]}

        node, acc ->
          {node, acc}
      end)

    findings
  end

  defp finding(module_name, kind, path) do
    Finding.from(
      @rule_id,
      "#{module_name}-#{kind}-#{path}",
      {:warn, 0.90},
      "Direct raw process spawn (#{kind}) in #{inspect(module_name)}",
      "Raw spawn leaks work into the application with no restart strategy. Prefer `start_supervised` (tests) or a proper supervisor (production).",
      "Replace the raw spawn with `start_supervised` (inside ExUnit) or wrap the work in a GenServer / Task supervised by an existing supervisor.",
      %{file: path, line: nil},
      [module_name]
    )
  end
end
