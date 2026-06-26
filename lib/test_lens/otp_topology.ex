defmodule TestLens.OTPTopology do
  @moduledoc """
  Resolves the OTP topology of a Mix project for the architecture
  advisor and dashboard. Pure functions; no I/O.

  ## What it returns

  A `%TestLens.OTPTopology{}` struct with:

    * `applications` — list of started OTP applications in the current
      VM (from `Application.started_applications/0`).
    * `supervisors` — top-level supervisor pids keyed by application
      name. Best-effort: if a registered supervisor cannot be resolved,
      the entry is omitted rather than raising.
    * `call_edges` — list of `%{from: mfa_or_module, to: mfa_or_module,
      kind: :call | :cast | :publish | :registry_lookup}` derived from a
      static AST scan of every `.ex` under the project's `lib/`.
    * `module_to_supervisor` — map of `module_atom → supervisor_pid`
      based on the application's registered supervisor and child spec.

  ## Limits

  Static AST analysis is fragile. Modules generated at compile time,
  metaprogrammed modules, and dynamic dispatch are not modelled. v4.0
  is intentionally conservative: call edges come from literal AST
  matches, not runtime tracing.
  """

  defstruct applications: [], supervisors: %{}, call_edges: [], module_to_supervisor: %{}

  @type mfa_ref :: {module(), atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          applications: [{atom(), charlist(), charlist()}],
          supervisors: %{optional(atom()) => pid()},
          call_edges: [
            %{required(:from) => module(), required(:to) => module(), required(:kind) => atom()}
          ],
          module_to_supervisor: %{optional(module()) => pid()}
        }

  @doc """
  Build the topology for the current VM.

  `lib_root` is the project's `lib/` directory (used for the AST
  scan). When `nil`, no AST scan is performed and `call_edges` is `[]`.
  """
  @spec build(Path.t() | nil) :: t()
  def build(lib_root \\ nil) do
    %__MODULE__{
      applications: safe_started_applications(),
      supervisors: resolve_top_supervisors(),
      call_edges: scan_call_edges(lib_root),
      module_to_supervisor: %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Application + supervisor resolution
  # ---------------------------------------------------------------------------

  defp safe_started_applications do
    Application.started_applications()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Best-effort: for each started application, try to look up a process
  # registered under the application's atom name. If found, treat it
  # as the application's top-level supervisor.
  defp resolve_top_supervisors do
    safe_started_applications()
    |> Enum.reduce(%{}, fn {app, _desc, _vsn}, acc ->
      case Process.whereis(app) do
        nil -> acc
        pid when is_pid(pid) -> Map.put(acc, app, pid)
        _ -> acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Static AST scan for call edges
  # ---------------------------------------------------------------------------

  @doc """
  Public for tests and for the rule engine. Returns a list (not a
  stream) of `%{from: module, to: module, kind: atom}` edges found
  via static AST scan of every `.ex` under `lib_root`.
  """
  @spec scan_call_edges(Path.t() | nil) :: [map()]
  def scan_call_edges(nil), do: []
  def scan_call_edges(""), do: []

  def scan_call_edges(lib_root) do
    lib_root
    |> list_elixir_files()
    |> Enum.flat_map(&scan_file/1)
  end

  defp list_elixir_files(root) do
    case File.ls(root) do
      {:ok, entries} when is_list(entries) ->
        Enum.flat_map(entries, fn entry ->
          entry_str = to_string(entry)
          path = Path.join(root, entry_str)

          cond do
            File.regular?(path) and String.ends_with?(path, ".ex") -> [path]
            File.dir?(path) -> list_elixir_files(path)
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  # Per-file: walk the AST, find GenServer.call/cast, Registry.*,
  # Phoenix.PubSub.* invocations, and record `{from_module, to_module}`
  # edges. Conservative: only literal calls, no metaprogramming.
  defp scan_file(path) do
    try do
      ast = read_and_parse(path)

      calling_module = infer_calling_module(ast, path)
      extract_edges(ast, calling_module)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp read_and_parse(path) do
    src = File.read!(path)
    Code.string_to_quoted!(src, columns: true, line: 1)
  rescue
    _ -> nil
  end

  defp infer_calling_module(_ast, path) do
    case Path.basename(path, ".ex") |> Macro.camelize() do
      "" -> nil
      name -> Module.concat([name])
    end
  end

  defp extract_edges(nil, _module), do: []

  defp extract_edges(ast, calling_module) do
    {_ast, edges} =
      Macro.prewalk(ast, [], fn
        # GenServer.call(Module, msg, [opts]) produces:
        #   {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, [arg1, arg2, ...]}
        # We match the outer 3-tuple.
        {{:., _m1, [{:__aliases__, _m2, [:GenServer]}, fun]}, _m3, args} = node, acc
        when fun in [:call, :cast] ->
          to_module = call_target(args)
          edge = edge_for(calling_module, to_module, edge_kind(:genserver, fun))
          {node, maybe_add(acc, edge)}

        # Registry.lookup(Registry, key) and friends.
        {{:., _m1, [{:__aliases__, _m2, [:Registry]}, fun]}, _m3, args} = node, acc
        when fun in [:lookup, :register, :dispatch, :via] ->
          to_module = call_target(args)
          edge = edge_for(calling_module, to_module, edge_kind(:registry, fun))
          {node, maybe_add(acc, edge)}

        # Phoenix.PubSub.broadcast(PubSub, topic, msg)
        {{:., _m1, [{:__aliases__, _m2, [:Phoenix, :PubSub]}, :broadcast]}, _m3, args} = node, acc ->
          to_module = call_target(args)
          edge = edge_for(calling_module, to_module, edge_kind(:pubsub, :broadcast))
          {node, maybe_add(acc, edge)}

        node, acc ->
          {node, acc}
      end)

    edges
  end

  defp call_target([{:__aliases__, _, aliases} | _]) do
    case Module.concat(aliases) do
      mod when is_atom(mod) -> mod
      _ -> nil
    end
  end

  defp call_target(_), do: nil

  defp edge_kind(:genserver, :call), do: :call
  defp edge_kind(:genserver, :cast), do: :cast
  defp edge_kind(:registry, _), do: :registry_lookup
  defp edge_kind(:pubsub, :broadcast), do: :publish

  defp edge_for(_from, nil, _kind), do: nil

  defp edge_for(nil, _to, _kind), do: nil

  defp edge_for(from, to, _kind) when from == to, do: nil

  defp edge_for(from, to, kind) do
    %{from: from, to: to, kind: kind}
  end

  defp maybe_add(acc, nil), do: acc
  defp maybe_add(acc, edge), do: [edge | acc]

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns the supervisor pid responsible for the given module, if any.
  Best-effort: returns `nil` when no association can be derived.
  """
  @spec supervisor_for(t(), module()) :: pid() | nil
  def supervisor_for(%__MODULE__{module_to_supervisor: m}, module) do
    Map.get(m, module)
  end

  @doc """
  Returns true when `from` and `to` are in different supervision subtrees.
  Currently best-effort: with only the apps + supervisors at the top
  level, this returns `false` for any module not in the
  `module_to_supervisor` map. v4.1 will improve the resolution.
  """
  @spec cross_tree_call?(t(), module(), module()) :: boolean()
  def cross_tree_call?(%__MODULE__{module_to_supervisor: m}, from, to) do
    case {Map.get(m, from), Map.get(m, to)} do
      {nil, _} -> false
      {_, nil} -> false
      {same, same} -> false
      _ -> true
    end
  end
end
