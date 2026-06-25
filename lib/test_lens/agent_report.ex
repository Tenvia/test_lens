defmodule TestLens.AgentReport do
  @moduledoc """
  Builds and writes the TestLens **agent repair artifact** — a
  machine-first JSON document that AI coding agents consume to triage
  failing Elixir tests.

  ## Purpose

  The TTY and HTML reports are written for humans. The agent artifact is
  written for code-fixing agents. It carries:

    * Stable failure identities and grouping fingerprints.
    * Application vs framework vs dependency stacktrace splits.
    * The top application frame (where to look first).
    * Ranked `repair_queue` items with first-checks and exact rerun
      commands.
    * Hedged root-cause hypotheses sourced from the classifier.
    * **(3.0+)** OTP runtime snapshots when `--snapshot` is enabled:
      supervision subtree, process info, telemetry event buffer, and
      safety metadata. See `docs/otp-snapshots.md`.

  ## What is NOT included

  Same discipline as the JSON artifact:

    * No environment variables.
    * No `Mix.Project.config/0`.
    * No raw ExUnit logs.
    * No raw message payloads from GenServer / mailbox captures.

  ## Default location

  `_build/test_lens/agent.json`

  ## Schema (`schema_version: "2.0"`)

      %{
        "schema_version"     => "2.0",
        "test_lens_version"  => "2.0.0",
        "run"                => %{"command" => ..., "cwd" => ..., "elixir" => ..., "otp" => ...},
        "totals"             => %{"tests" => ..., "passed" => ..., "failed" => ..., "skipped" => ..., "invalid" => ..., "excluded" => ...},
        "failures"           => [ %{"id" => ..., "module" => ..., "name" => ..., "file" => ..., "line" => ..., "classification" => ..., "impact" => ..., "failure_kind" => ..., "severity" => ..., "fingerprint" => ..., "top_app_frame" => ..., "app_stacktrace" => [...], "framework_stacktrace" => [...], "deps_stacktrace" => [...], "hypotheses" => [...], "rerun_command" => ...}, ... ],
        "repair_queue"       => [ %{"id" => ..., "priority" => ..., "confidence" => ..., "failure_ids" => [...], "root_cause_fingerprint" => ..., "summary" => ..., "evidence" => [...], "likely_files" => [...], "first_checks" => [...], "verification_commands" => [...]}, ... ],
        "commands"           => [...],
        "safety"             => %{"excluded_fields" => [...], "notes" => ...}
      }
  """

  alias TestLens.{Classifier, Fingerprint, Impact, JSONReport, ProjectConfig, Result, Stacktrace}

  @default_path "_build/test_lens/agent.json"
  @schema_version "3.0"

  @doc "Returns the default artifact path."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc "Returns the JSON `schema_version` string emitted by this build."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  Build the agent repair artifact as an Elixir map. Pure function; no I/O.
  """
  @spec build([Result.t()], map(), integer() | :random | nil) :: map()
  def build(results, times_us, seed), do: build(results, times_us, seed, nil)

  @doc """
  Build the agent repair artifact with optional OTP snapshots (3.0+).

  `otp_snapshots` is a map of `%{failure_id => snapshot_map}`. Each
  snapshot is the shape returned by `TestLens.OTPSnapshot.capture_for_failure/3`
  with an additional `"telemetry_events"` key carrying the bridge's
  event buffer at the moment of failure. When `otp_snapshots` is `nil`
  or empty, the artifact's `otp_snapshots` array is empty and
  `failures[]` entries do NOT carry an `otp_context` field.
  """
  @spec build([Result.t()], map(), integer() | :random | nil, map() | nil) :: map()
  def build(results, times_us, seed, otp_snapshots) do
    failed = Enum.filter(results, &Result.failed?/1)
    failures = Enum.map(failed, &failure_entry/1)
    fingerprint_groups = group_by_fingerprint(failures)
    snapshots = otp_snapshots || %{}

    %{
      "schema_version" => @schema_version,
      "test_lens_version" => TestLens.version(),
      "project" => ProjectConfig.load_or_default().project,
      "run" => run_info(times_us, seed),
      "totals" => totals(results),
      "failures" => attach_otp_context(failures, snapshots),
      "repair_queue" => repair_queue(fingerprint_groups, failures),
      "commands" => commands(seed, failed != []),
      "otp_snapshots" => otp_snapshots_list(snapshots),
      "safety" => safety_block()
    }
  end

  # When OTP snapshots are present, attach a small pointer onto each
  # failure entry so consumers don't need to walk the top-level
  # `otp_snapshots` array to find context for a specific failure. The
  # full snapshot stays in `otp_snapshots[]` for human review.
  defp attach_otp_context(failures, snapshots) do
    Enum.map(failures, fn failure ->
      case Map.get(snapshots, failure["id"]) do
        nil -> failure
        snap -> Map.put(failure, "otp_context", %{"snapshot_id" => snap["snapshot_id"]})
      end
    end)
  end

  defp otp_snapshots_list(snapshots) do
    snapshots
    |> Enum.sort_by(fn {_id, snap} -> snap["captured_at"] end)
    |> Enum.map(fn {_id, snap} -> snap end)
  end

  @doc """
  Encode a built agent artifact to a JSON string. Delegates to
  `TestLens.JSONReport.encode/1` so the agent artifact uses the same
  encoder as the human-facing JSON artifact.
  """
  @spec encode(map()) :: String.t()
  def encode(artifact), do: JSONReport.encode(artifact)

  @doc """
  Build and write the agent artifact to `path`. Creates parent directories
  if they do not exist.
  """
  @spec write(Path.t(), [Result.t()], map(), integer() | :random | nil) ::
          :ok | {:error, term()}
  def write(path, results, times_us, seed) do
    write(path, results, times_us, seed, nil)
  end

  @doc """
  Build and write the agent artifact with optional OTP snapshots (3.0+).
  """
  @spec write(Path.t(), [Result.t()], map(), integer() | :random | nil, map() | nil) ::
          :ok | {:error, term()}
  def write(path, results, times_us, seed, otp_snapshots) do
    payload = encode(build(results, times_us, seed, otp_snapshots))

    try do
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, payload)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Failure entry
  # ---------------------------------------------------------------------------

  defp failure_entry(%Result{} = r) do
    {kind, reason, stacktrace} = first_failure_tuple(r)
    classification = Classifier.classify_failure({kind, reason, stacktrace || []})

    impact_struct = Impact.classify(r)
    impact = impact_struct |> Map.from_struct() |> stringify_keys()

    line = Result.line(r) || stacktrace_top_line(stacktrace)

    %{
      "id" => failure_id(r),
      "module" => inspect(r.module),
      "name" => Atom.to_string(r.name),
      "file" => r.file,
      "line" => line,
      "time_us" => r.time_us,
      "failure_kind" => stringify_failure_kind({kind, reason, stacktrace || []}),
      "severity" => severity(classification),
      "classification" => stringify_keys(classification),
      "impact" => impact,
      "fingerprint" => fingerprint_for(r, classification, stacktrace),
      "top_app_frame" => top_app_frame(stacktrace),
      "app_stacktrace" => app_stacktrace(stacktrace),
      "framework_stacktrace" => framework_stacktrace(stacktrace),
      "deps_stacktrace" => deps_stacktrace(stacktrace),
      "hypotheses" => hypotheses(classification),
      "rerun_command" => rerun_command(r)
    }
  end

  defp first_failure_tuple(%Result{failures: [{kind, reason, stack} | _]})
       when is_atom(kind),
       do: {kind, reason, stack}

  defp first_failure_tuple(%Result{status: :invalid}), do: {:invalid, nil, []}
  defp first_failure_tuple(_), do: {:unknown, nil, []}

  defp stringify_failure_kind({kind, reason, _}) when is_atom(kind) do
    cond do
      kind == :exit and reason == :timeout -> "exit_timeout"
      kind == :exit -> "exit_" <> stringify(reason)
      true -> Atom.to_string(kind)
    end
  end

  defp stringify_failure_kind(_), do: "unknown"

  defp severity(%{default_severity: s}) when is_atom(s), do: Atom.to_string(s)
  defp severity(_), do: "other"

  defp fingerprint_for(r, classification, stacktrace) do
    Fingerprint.compute(%{
      kind: failure_kind_atom(r),
      classification_type: Map.get(classification, :type),
      file: r.file,
      top_app_frame: frame_signature(Stacktrace.top_app_frame(stacktrace || []))
    })
  end

  defp failure_kind_atom(%Result{status: :invalid}), do: :invalid
  defp failure_kind_atom(%Result{failures: [{kind, _, _} | _]}) when is_atom(kind), do: kind
  defp failure_kind_atom(_), do: :unknown

  defp frame_signature(nil), do: nil

  defp frame_signature(%{
         "module" => module,
         "function" => function,
         "arity" => arity
       }) do
    "#{module}.#{function}/#{arity}"
  end

  defp stacktrace_top_line(nil), do: nil
  defp stacktrace_top_line([]), do: nil

  defp stacktrace_top_line([_ | _] = frames) do
    case Stacktrace.top_app_frame(frames) do
      %{"line" => line} when is_integer(line) -> line
      _ -> nil
    end
  end

  defp top_app_frame(nil), do: nil
  defp top_app_frame(stacktrace), do: Stacktrace.top_app_frame(stacktrace)

  defp app_stacktrace(nil), do: []
  defp app_stacktrace(stacktrace), do: Map.get(Stacktrace.split(stacktrace), "app", [])

  defp framework_stacktrace(nil), do: []

  defp framework_stacktrace(stacktrace),
    do: Map.get(Stacktrace.split(stacktrace), "framework", [])

  defp deps_stacktrace(nil), do: []
  defp deps_stacktrace(stacktrace), do: Map.get(Stacktrace.split(stacktrace), "deps", [])

  defp hypotheses(%{
         type: type,
         plain_english: plain_english,
         common_causes: common_causes,
         suggested_checks: suggested_checks
       }) do
    [
      %{
        "type" => type |> stringify(),
        "summary" => plain_english,
        "common_causes" => common_causes,
        "first_checks" => suggested_checks
      }
    ]
  end

  defp hypotheses(_), do: []

  defp rerun_command(%Result{file: file, name: name}) when is_binary(file) do
    "mix test.lens -- #{file}:#{guess_line(file, name)}"
  end

  defp rerun_command(%Result{}), do: "mix test.lens -- --failed"

  # Without line numbers, point agents at the whole file — they can grep
  # for the test name. The formatter writes the precise rerun line once
  # ExUnit exposes it in a future version.
  defp guess_line(_file, _name), do: ""

  # ---------------------------------------------------------------------------
  # Repair queue: group failures by fingerprint, rank by priority
  # ---------------------------------------------------------------------------

  defp group_by_fingerprint(failures) do
    failures
    |> Enum.group_by(& &1["fingerprint"])
    |> Enum.map(fn {fingerprint, group} ->
      {fingerprint, group, Enum.map(group, & &1["id"])}
    end)
  end

  defp repair_queue(groups, failures) do
    groups
    |> Enum.map(fn {fingerprint, group, failure_ids} ->
      %{
        "id" => "repair_" <> short_id(fingerprint),
        "priority" => priority(group),
        "confidence" => confidence(group),
        "failure_ids" => failure_ids,
        "root_cause_fingerprint" => fingerprint,
        "summary" => summary_for(group),
        "evidence" => evidence_for(group),
        "likely_files" => likely_files_for(group),
        "first_checks" => first_checks_for(group),
        "verification_commands" => verification_commands_for(failure_ids, failures)
      }
    end)
    |> Enum.sort_by(&{-priority_score(&1), &1["root_cause_fingerprint"]})
  end

  # Priority: critical + user_facing + high-impact → 1 (highest). Ties break
  # on impact severity (high > medium > low > none).
  defp priority(group) do
    cond do
      Enum.any?(group, fn f -> f["severity"] == "critical" end) -> "critical"
      Enum.any?(group, fn f -> get_in(f, ["impact", "user_facing"]) == true end) -> "user_facing"
      Enum.any?(group, fn f -> get_in(f, ["impact", "impact"]) == "high" end) -> "high"
      true -> "normal"
    end
  end

  defp priority_score(%{"priority" => "critical"}), do: 100
  defp priority_score(%{"priority" => "user_facing"}), do: 50
  defp priority_score(%{"priority" => "high"}), do: 25
  defp priority_score(_), do: 1

  # Confidence is coarse: a recognized classification type plus a top app
  # frame means high confidence. Unknown classification with no app frame
  # means low.
  defp confidence(group) do
    score =
      if Enum.any?(group, fn f ->
           get_in(f, ["classification", "type"]) not in [nil, "unknown"]
         end) do
        0.7
      else
        0.3
      end

    bump =
      if Enum.any?(group, fn f -> f["top_app_frame"] != nil end) do
        0.2
      else
        0.0
      end

    Float.round(min(score + bump, 0.95), 2)
  end

  defp summary_for(group) do
    [head | _] = group
    module = head["module"]
    name = head["name"]
    type = get_in(head, ["classification", "type"])
    "#{module} > #{name} (#{type || "unknown"})"
  end

  defp evidence_for(group) do
    Enum.flat_map(group, fn f ->
      frame = f["top_app_frame"]

      if frame,
        do: [
          "#{frame["module"]}.#{frame["function"]}/#{frame["arity"]} at #{frame["file"]}:#{frame["line"]}"
        ],
        else: []
    end)
    |> Enum.uniq()
  end

  defp likely_files_for(group) do
    Enum.flat_map(group, fn f ->
      [f["file"], get_in(f, ["top_app_frame", "file"])]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp first_checks_for(group) do
    group
    |> Enum.flat_map(fn f -> get_in(f, ["classification", "suggested_checks"]) || [] end)
    |> Enum.uniq()
  end

  defp verification_commands_for(failure_ids, failures) do
    failure_ids
    |> Enum.map(fn id -> Enum.find(failures, &(&1["id"] == id)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1["rerun_command"])
    |> Enum.uniq()
  end

  defp short_id(fingerprint) do
    binary = Base.decode16!(fingerprint, case: :mixed)

    binary
    |> :binary.bin_to_list()
    |> Enum.take(4)
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Run info, totals, commands, safety
  # ---------------------------------------------------------------------------

  defp run_info(_times_us, seed) do
    %{
      "command" => "mix test.lens",
      "cwd" => File.cwd!(),
      "elixir" => System.version(),
      "seed" => seed_to_string(seed)
    }
  end

  defp seed_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp seed_to_string(:random), do: "random"
  defp seed_to_string(_), do: nil

  defp totals(results) do
    %{
      "tests" => length(results),
      "passed" => Enum.count(results, &Result.passed?/1),
      "failed" => Enum.count(results, &Result.failed?/1),
      "skipped" => Enum.count(results, &Result.skipped?/1),
      "excluded" => Enum.count(results, fn r -> r.status == :excluded end),
      "invalid" => Enum.count(results, fn r -> r.status == :invalid end)
    }
  end

  defp commands(_seed, _has_failures = false) do
    [%{"command" => "mix test.lens -- --stale", "comment" => "check for stale tests"}]
  end

  defp commands(seed, _has_failures = true) do
    base = [
      %{"command" => "mix test.lens -- --failed", "comment" => "rerun the failing tests"},
      %{"command" => "mix test.lens -- --stale", "comment" => "check for stale tests"}
    ]

    case seed do
      n when is_integer(n) ->
        base ++
          [%{"command" => "mix test.lens -- --seed #{n}", "comment" => "reproduce this run"}]

      _ ->
        base
    end
  end

  defp safety_block do
    %{
      "excluded_fields" => [
        "env",
        "mix_project_config",
        "application_config",
        "exunit_logs",
        "raw_message_payloads"
      ],
      "notes" =>
        "The agent artifact contains deterministic failure context only. " <>
          "It does not include environment variables, application configuration, " <>
          "raw ExUnit logs, or raw message payloads. Consumers should treat all " <>
          "string fields as already scrubbed of secrets by the time they appear here."
    }
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns the 12-hex-char stable identifier for a failure entry.
  Shared by the Formatter (which keys snapshot captures by failure id)
  and the AgentReport (which keys failure entries by the same id).
  """
  @spec failure_id(Result.t()) :: String.t()
  def failure_id(%Result{} = r) do
    raw = "#{inspect(r.module)}.#{r.name}.#{r.file}"
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: to_string(v)

  # Convert a map with atom keys to a map with string keys, recursively.
  # Mirrors TestLens.JSONReport.stringify_keys/1 so nested classification
  # and impact maps serialize correctly without depending on private helpers.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string_key(k), stringify_value(v)} end)
  end

  defp stringify_keys(other), do: other

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and v != true and v != false,
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: k
end
