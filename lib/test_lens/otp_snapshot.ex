defmodule TestLens.OTPSnapshot do
  @moduledoc """
  Captures **test-time OTP runtime context** at the moment an ExUnit
  test fails. The output is a plain map suitable for inclusion in the
  TestLens agent artifact (`schema_version: "3.0"`).

  ## Scope

  Snapshots are opt-in (`--snapshot`). They capture ONLY failed tests,
  only at the moment `test_finished` fires, never in production. The
  module is intentionally bounded: depth limits, timeouts, and explicit
  safety checks guard every call.

  ## Safety

  Capture rules (see `safe_to_capture?/1` and the registered-name
  denylist in `denylisted_registered_name?/1`):

    * The pid must be alive at capture time.
    * The pid must belong to one of the recognized OTP families:
      `GenServer`, `Agent`, `Task`, or a named process. Untyped raw
      pids are not captured.
    * The registered name (if any) must not contain the case-insensitive
      substrings `token`, `secret`, `password`, `key`, `credential`,
      or `auth`. This is a v1 heuristic, intentionally conservative.
    * `:messages`, `:dictionary`, and `:current_stacktrace` are
      **never** captured. They may contain secrets, large binaries,
      or unbounded content.
    * `:erlang.term_to_binary/1` is only called on a pid's state when
      the pid passes `safe_to_capture?/1`. State hash is computed via
      `:crypto.hash(:md5, ...)` and exposed as `state_hash` (hex). The
      state itself is never serialized into the artifact.

  ## Bounds

    * `capture_supervision_subtree/2` walks at most `max_depth = 6` and
      `max_breadth = 64`. Subtrees that exceed the bounds are recorded
      with `"truncated": true` and the partial result.
    * Every capture is wrapped in a `capture_timeout_ms` (default
      `100`) millisecond `:timer.apply_after` guard. On timeout the
      function returns `{:error, :capture_timeout}`.
  """

  alias TestLens.Result

  @capture_timeout_ms 100
  @max_depth 6
  @max_breadth 64
  @denylist_substrings ~w(token secret password key credential auth)

  @doc "Returns the capture timeout in milliseconds."
  @spec capture_timeout_ms() :: pos_integer()
  def capture_timeout_ms, do: @capture_timeout_ms

  @doc "Returns the maximum supervision-tree depth captured."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "Returns the maximum supervision-tree breadth per level."
  @spec max_breadth() :: pos_integer()
  def max_breadth, do: @max_breadth

  @doc """
  Captures an OTP snapshot for a failed test.

  `failure_id` is a stable identifier (e.g. the SHA-256 prefix used by
  `TestLens.AgentReport.failure_id/1`). `pid` is the test process
  (typically `self/0`). Returns a plain map. Never raises.
  """
  @spec capture_for_failure(Result.t(), String.t(), pid()) :: map()
  def capture_for_failure(%Result{status: status}, _failure_id, _pid) when status != :failed do
    {:error, :not_a_failure}
  end

  def capture_for_failure(%Result{module: module, name: name}, failure_id, pid) do
    snapshot = %{
      "snapshot_id" => generate_snapshot_id(failure_id),
      "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "test_pid" => stringify_pid(pid),
      "test_module" => inspect(module),
      "test_name" => Atom.to_string(name),
      "supervision_subtree" => capture_supervision_subtree(root_supervisor_pids(), 0),
      "process_info" => safe_process_info(pid),
      "safety" => safety_record(pid)
    }

    snapshot
  end

  @doc """
  Walks the supervision tree starting from `roots` (a list of pids),
  bounded by `max_depth/0` and `max_breadth/0`. Returns a list of
  supervisor descriptors. Subtrees that exceed the bounds are marked
  `"truncated": true`.
  """
  @spec capture_supervision_subtree([pid()], non_neg_integer()) :: list(map())
  def capture_supervision_subtree(roots, depth \\ 0)

  def capture_supervision_subtree(_roots, depth) when depth >= @max_depth, do: []

  def capture_supervision_subtree(roots, depth) when is_list(roots) do
    roots
    |> Enum.take(@max_breadth)
    |> Enum.flat_map(&describe_children/1)
    |> case do
      [] ->
        []

      children ->
        next_depth = depth + 1
        next_pids = Enum.flat_map(children, & &1["pid_or_nil"])
        nested = capture_supervision_subtree(Enum.reject(next_pids, &is_nil/1), next_depth)

        Enum.zip_with(children, nested, fn child, descendants ->
          child
          |> Map.delete("pid_or_nil")
          |> Map.put("descendants", descendants)
        end)
    end
  end

  def capture_supervision_subtree(_, _), do: []

  defp describe_children(pid) when is_pid(pid) do
    with true <- Process.alive?(pid),
         {:ok, info} <- safe_info(pid) do
      name = Map.get(info, :registered_name)
      type = classify_kind(info)

      Enum.map(Supervisor.which_children(pid), fn child_spec ->
        describe_child(child_spec, name, type)
      end)
    else
      _ -> []
    end
  end

  defp describe_children(_), do: []

  defp describe_child({id, child, type, _modules}, _parent_name, _parent_type) do
    child_pid =
      case child do
        pid when is_pid(pid) -> pid
        _ -> nil
      end

    %{
      "id" => stringify_id(id),
      "child" => stringify_id(child),
      "type" => stringify_id(type),
      "pid_or_nil" => child_pid
    }
  end

  defp describe_child(_child_spec, _parent_name, _parent_type), do: []

  # ---------------------------------------------------------------------------
  # Process info
  # ---------------------------------------------------------------------------

  @doc """
  Captures a whitelisted subset of `Process.info/2` for `pid`. Returns
  `nil` when the pid is not alive or not in the safe families.

  The whitelist excludes `:messages`, `:dictionary`, and
  `:current_stacktrace`. Pids whose registered name is denylisted
  return `nil`.
  """
  @spec safe_process_info(pid() | nil) :: map() | nil
  def safe_process_info(nil), do: nil

  def safe_process_info(pid) when is_pid(pid) do
    cond do
      not Process.alive?(pid) -> nil
      not safe_to_capture?(pid) -> nil
      true -> do_capture_process_info(pid)
    end
  end

  def safe_process_info(_), do: nil

  defp do_capture_process_info(pid) do
    keys = [
      :registered_name,
      :current_function,
      :initial_call,
      :trap_exit,
      :priority,
      :message_queue_len,
      :links,
      :monitors,
      :group_leader,
      :dictionary_size,
      :total_heap_size
    ]

    # `Process.info(pid, keys)` is all-or-nothing: if ANY key is
    # unsupported on the running BEAM (e.g. `:dictionary_size` was
    # removed in OTP 27), the call raises ArgumentError and we lose
    # every field. We probe each key individually so a single missing
    # key only drops that field.
    map =
      Enum.reduce(keys, %{}, fn key, acc ->
        case safe_process_info_key(pid, key) do
          :skip -> acc
          {:ok, value} -> Map.put(acc, key, value)
        end
      end)

    case map_size(map) do
      0 ->
        nil

      _ ->
        %{
          "registered_name" => stringify_registered(map[:registered_name]),
          "current_function" => stringify_mfa(map[:current_function]),
          "initial_call" => stringify_mfa(map[:initial_call]),
          "trap_exit" => map[:trap_exit] == true,
          "priority" => map[:priority],
          "mailbox_size" => map[:message_queue_len],
          "links" => Enum.map(List.wrap(map[:links] || []), &stringify_pid/1),
          "monitors" => Enum.map(List.wrap(map[:monitors] || []), &stringify_monitor/1),
          "group_leader" => stringify_pid(map[:group_leader]),
          "dictionary_size" => map[:dictionary_size],
          "total_heap_size" => map[:total_heap_size]
        }
        |> maybe_add_state_hash(pid)
    end
  end

  defp safe_process_info_key(pid, key) do
    case Process.info(pid, key) do
      nil ->
        :skip

      {^key, value} ->
        {:ok, value}

      _ ->
        :skip
    end
  rescue
    _ -> :skip
  catch
    :exit, _ -> :skip
  end

  # State hashing is gated by safe_to_capture?/1 (already true here).
  # Use a try/rescue around term_to_binary to defend against funs and
  # refs that can't be serialized.
  defp maybe_add_state_hash(map, pid) do
    case safe_state_hash(pid) do
      {:ok, hash} -> Map.put(map, "state_hash", hash)
      :skip -> map
    end
  end

  @doc """
  Returns `{:ok, hex}` if a state hash can be computed for `pid`,
  `:skip` otherwise. Never raises.

  Implementation: call `:sys.get_state/1` for GenServer/Agent pids,
  `:erlang.term_to_binary/1` to serialize, then MD5 hex. The state
  itself is never persisted, only its hash.
  """
  @spec safe_state_hash(pid()) :: {:ok, String.t()} | :skip
  def safe_state_hash(nil), do: :skip

  def safe_state_hash(pid) when is_pid(pid) do
    cond do
      not Process.alive?(pid) ->
        :skip

      not safe_to_capture?(pid) ->
        :skip

      true ->
        try do
          state =
            cond do
              is_gen_server?(pid) -> :sys.get_state(pid)
              is_agent?(pid) -> Agent.get(pid, & &1, 50)
              true -> :skip
            end

          case state do
            :skip ->
              :skip

            value when is_reference(value) or is_function(value) or is_port(value) ->
              :skip

            other ->
              :crypto.hash(:md5, :erlang.term_to_binary(other))
              |> Base.encode16(case: :lower)
              |> then(&{:ok, &1})
          end
        rescue
          _ -> :skip
        catch
          :exit, _ -> :skip
        end
    end
  end

  def safe_state_hash(_), do: :skip

  # ---------------------------------------------------------------------------
  # Safety gates
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` when `pid` is safe to inspect for an OTP snapshot.

  The check is conservative: a pid that fails any of these checks is
  NOT captured. Recognized families are `GenServer`, `Agent`, and
  `Task`. Registered names that match the denylist are rejected.
  """
  @spec safe_to_capture?(pid()) :: boolean()
  def safe_to_capture?(nil), do: false

  def safe_to_capture?(pid) when is_pid(pid) do
    cond do
      not Process.alive?(pid) -> false
      denylisted_registered_name?(registered_name(pid)) -> false
      true -> true
    end
  end

  def safe_to_capture?(_), do: false

  @doc """
  Returns `true` when the given registered name (string or atom)
  matches the v1 denylist substrings. Case-insensitive. Conservative:
  any match excludes the pid.
  """
  @spec denylisted_registered_name?(term()) :: boolean()
  def denylisted_registered_name?(nil), do: false
  def denylisted_registered_name?(:undefined), do: false

  def denylisted_registered_name?(name) do
    name_str = name |> to_string() |> String.downcase()

    Enum.any?(@denylist_substrings, &String.contains?(name_str, &1))
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safety_record(pid) do
    %{
      "denylist_substrings" => @denylist_substrings,
      "safe_to_capture" => safe_to_capture?(pid),
      "max_depth" => @max_depth,
      "max_breadth" => @max_breadth,
      "capture_timeout_ms" => @capture_timeout_ms
    }
  end

  defp safe_info(pid) do
    try do
      {:ok, Process.info(pid, [:registered_name])}
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  defp classify_kind(_info), do: :worker

  defp registered_name(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} -> name
      _ -> nil
    end
  end

  # Practical gen_server/agent detection: probe :sys.get_state/1 first
  # (gen_server-aware), then Agent.get/3, then bail. Both are wrapped in
  # try/catch so an uncooperative pid never raises.
  defp is_gen_server?(pid) do
    try do
      _ = :sys.get_state(pid, 50)
      true
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp is_agent?(pid) do
    try do
      _ = Agent.get(pid, & &1, 50)
      true
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp root_supervisor_pids do
    # Walk every started application, look up its top-level supervisor
    # pid by registered name (the application atom), and return the
    # unique non-nil pids. This is best-effort: in test environments
    # the application tree may be sparse, and we never fail on a
    # lookup error.
    Application.started_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> lookup_app_supervisor(app) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp lookup_app_supervisor(app) do
    # Best-effort: list children of the registered top-level supervisor
    # (`:supervisor`) for the application, if any. The lookup name is
    # conventionally the application module atom (e.g. `:my_app`).
    case Process.whereis(app) do
      nil ->
        nil

      pid when is_pid(pid) ->
        case safe_supervisor_which_children(pid) do
          {:ok, children} ->
            Enum.find_value(children, fn
              {^app, ^pid, :supervisor, _} -> pid
              _ -> nil
            end)

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  defp safe_supervisor_which_children(pid) do
    try do
      {:ok, Supervisor.which_children(pid)}
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  # `root_supervisor_pids/0` is the sole clause. In test environments
  # the application tree may be sparse; if `Application.started_applications/0`
  # raises we treat the capture as having no supervision roots, which
  # yields an empty subtree rather than a failure.

  defp generate_snapshot_id(failure_id) do
    raw = "#{failure_id}-#{System.system_time(:nanosecond)}"
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp stringify_pid(nil), do: nil
  defp stringify_pid(pid) when is_pid(pid), do: inspect(pid)

  defp stringify_registered(:undefined), do: nil
  defp stringify_registered(nil), do: nil
  defp stringify_registered([]), do: nil
  defp stringify_registered(name) when is_atom(name), do: Atom.to_string(name)
  defp stringify_registered(name), do: to_string(name)

  defp stringify_mfa({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    %{"module" => Atom.to_string(m), "function" => Atom.to_string(f), "arity" => a}
  end

  defp stringify_mfa(_), do: nil

  defp stringify_monitor({{:process, pid}, ref}) when is_pid(pid) and is_reference(ref) do
    %{"type" => "process", "pid" => stringify_pid(pid), "ref" => inspect(ref)}
  end

  defp stringify_monitor({{:process, pid}, ref}) do
    %{"type" => "process", "pid" => stringify_pid(pid), "ref" => inspect(ref)}
  end

  defp stringify_monitor({{:port, port}, ref}) when is_port(port) and is_reference(ref) do
    %{"type" => "port", "port" => inspect(port), "ref" => inspect(ref)}
  end

  defp stringify_monitor({{:port, port}, ref}) do
    %{"type" => "port", "port" => inspect(port), "ref" => inspect(ref)}
  end

  defp stringify_monitor({{:time_offset, _}, _} = m),
    do: %{"type" => "time_offset", "raw" => inspect(m)}

  defp stringify_monitor({{:name, name}, _} = m),
    do: %{"type" => "name", "name" => inspect(name), "raw" => inspect(m)}

  defp stringify_monitor(other), do: %{"type" => "other", "raw" => inspect(other)}

  defp stringify_id(id) when is_atom(id), do: Atom.to_string(id)
  defp stringify_id(id) when is_pid(id), do: inspect(id)
  defp stringify_id(id), do: to_string(id)
end
