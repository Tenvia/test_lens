defmodule TestLens.JSONReport do
  @moduledoc """
  Builds and writes the TestLens JSON artifact for agent and CI consumption.

  ## What this is

  When you run `mix test.lens --json` (or `mix test.lens --json-file PATH`),
  TestLens writes a structured JSON document to a file. The document is the
  same data the human-facing TTY report shows, but in a form that is easy
  for AI agents, CI scripts, and other tools to consume without having to
  scrape or parse terminal output.

  ## Default location

  `_build/test_lens/report.json` (relative to the project root).

  ## Schema (v0.1.0)

  The artifact is a single JSON object with the following top-level keys.
  Field names are stable; new fields may be added in minor versions.

      %{
        "test_lens_version" => "0.1.0",
        "project"           => "ExampleApp" | null,   # from .test_lens.exs :project
        "timestamp"         => "2026-06-24T10:00:00.000000Z",  # ISO 8601 UTC
        "seed"              => 12345 | :random | nil,         # ExUnit seed
        "totals"            => %{
          "tests"    => 50,
          "passed"   => 45,
          "failed"   => 2,
          "skipped"  => 3,
          "excluded" => 0,
          "invalid"  => 0
        },
        "times_us"          => %{ "run" => 1234, "async" => 567, "load" => null },
        "failures"          => [ ... ],
        "slow"              => [ ... ],
        "classification_counts" => %{ "function_clause" => 1, "assertion" => 1, ... },
        "next_commands"     => [ ... ]
      }

  Each entry in `failures` is a JSON object:

      %{
        "module"         => "MyApp.UserAuthTest",
        "name"           => "test login with valid credentials",
        "file"           => "test/user_auth_test.exs" | null,
        "line"           => null,           # ExUnit does not expose line numbers
        "time_us"        => 5000,
        "tags"           => ["integration"],
        "failure_kind"   => "function_clause" | "exit" | "throw" | "invalid",
        "severity"       => "critical" | "other",
        "classification" => %{              # from TestLens.FailureAdapters
          "type"             => "function_clause",
          "likely_layer"     => "Contract / function boundary",
          "plain_english"    => "A function likely received data in a shape it does not handle.",
          "common_causes"    => [...],
          "suggested_checks" => [...],
          "default_severity" => "other"
        },
        "impact"          => %{              # from TestLens.Impact
          "area"        => "Accounts" | null,
          "impact"      => "high" | "medium" | "low" | "none",
          "user_facing" => true | false,
          "critical"    => true | false,
          "reason"      => "matches area \\"Accounts\\"" | "tagged critical: payment" | "no matching area or tag"
        }
      }

  Each entry in `slow` is a JSON object:

      %{
        "module"  => "MyAppWeb.PageControllerTest",
        "name"    => "test renders 1000 widgets",
        "file"    => "test/...",
        "time_us" => 145200
      }

  Each entry in `next_commands` is:

      %{
        "command" => "mix test.lens -- --failed",
        "comment" => "rerun the failing tests"
      }

  ## Stability

  This schema is part of the public v0.1.0 contract. Field names will not
  change without a major version bump. New fields may be added in minor
  versions. Consumers should ignore unknown fields.

  ## What is NOT included

  - No environment variables, no `System.get_env/1`, no shell dumps.
  - No `Mix.Project.config/0` (which can contain DB credentials, API
    keys, etc. for the consumer's project).
  - No ExUnit logs (logs may contain sensitive data).
  - No raw application config.

  If you need to add a field, prefer the MEANING of the failure (a
  classification, an impact, a file path) over the raw data.
  """

  alias TestLens.{Classifier, Impact, ProjectConfig, Result}
  alias TestLens.TerminalReporter

  @default_path "_build/test_lens/report.json"

  @doc "Returns the default artifact path."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc """
  Builds the JSON artifact as an Elixir map. Pure function — no I/O.
  Useful for tests and for callers that want to manipulate the data
  before encoding.
  """
  @spec build([Result.t()], map(), integer() | :random | nil) :: map()
  def build(results, times_us, seed) do
    failed = Enum.filter(results, &Result.failed?/1)

    %{
      "test_lens_version" => TestLens.version(),
      "project" => ProjectConfig.load_or_default().project,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "seed" => seed,
      "totals" => totals(results),
      "times_us" => times_us,
      "failures" => Enum.map(failed, &failure_entry/1),
      "slow" => slow_entries(results),
      "classification_counts" => classification_counts(failed),
      "next_commands" => next_commands(results, seed)
    }
  end

  @doc """
  Encodes a built artifact to a pretty-printed JSON string.
  """
  @spec encode(map()) :: String.t()
  def encode(artifact) do
    # Reuse TerminalReporter's JSON encoder by extracting the inner encoder.
    # The cleanest path: build the JSON via TerminalReporter's encode_json/1
    # private function. We expose encode_via_tr/1 as a public helper here.
    # If the existing encoder in TerminalReporter is not directly callable,
    # add a small public function there and call it. Keep the existing
    # render_json/4 unchanged in behaviour.
    encoded = encode_via_terminal(artifact)
    # encode_via_terminal already returns a JSON string.
    encoded
  end

  @doc """
  Builds and writes the artifact to `path`. Creates parent directories
  if they do not exist. Returns `:ok` on success or `{:error, reason}`.
  """
  @spec write(Path.t(), [Result.t()], map(), integer() | :random | nil) :: :ok | {:error, term()}
  def write(path, results, times_us, seed) do
    artifact = build(results, times_us, seed)
    payload = encode(artifact)

    try do
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, payload)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp failure_entry(%Result{} = r) do
    %{
      "module" => inspect(r.module),
      "name" => Atom.to_string(r.name),
      "file" => r.file,
      "line" => r.line,
      "time_us" => r.time_us,
      "tags" => stringify_tags(r.tags),
      "failure_kind" => failure_kind(r),
      "severity" => severity(r),
      "classification" => classify_failure_to_map(r),
      "impact" => impact_to_map(r)
    }
  end

  defp failure_kind(%Result{failures: [{kind, _reason, _stack} | _]}) when is_atom(kind),
    do: Atom.to_string(kind)
  defp failure_kind(%Result{status: :invalid}), do: "invalid"
  defp failure_kind(_), do: "unknown"

  defp severity(%Result{} = r) do
    tuple = to_failure_tuple(r)
    case Classifier.classify_failure(tuple) do
      %{default_severity: s} -> Atom.to_string(s)
    end
  end

  defp classify_failure_to_map(%Result{} = r) do
    tuple = to_failure_tuple(r)
    Classifier.classify_failure(tuple) |> stringify_keys()
  end

  defp impact_to_map(%Result{} = r) do
    r
    |> Impact.classify()
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp to_failure_tuple(%Result{failures: []} = r) when r.status == :invalid do
    {:invalid, nil, []}
  end
  defp to_failure_tuple(%Result{failures: [first | _] = fs}) when is_list(fs) do
    case first do
      {kind, reason, stack} when is_atom(kind) -> {kind, reason, stack}
      _ -> {:error, hd(fs), []}
    end
  end
  defp to_failure_tuple(%Result{}), do: {:error, nil, []}

  defp slow_entries(results) do
    results
    |> Enum.filter(fn r -> r.time_us > 0 end)
    |> Enum.sort_by(& &1.time_us, :desc)
    |> Enum.take(5)
    |> Enum.map(fn r ->
      %{
        "module" => inspect(r.module),
        "name" => Atom.to_string(r.name),
        "file" => r.file,
        "time_us" => r.time_us
      }
    end)
  end

  defp classification_counts(failures) do
    failures
    |> Enum.map(fn r ->
      tuple = to_failure_tuple(r)
      tuple
      |> Classifier.classify_failure()
      |> Map.fetch!(:type)
      |> Atom.to_string()
    end)
    |> Enum.frequencies()
  end

  defp next_commands(results, seed) do
    cmds = []

    cmds =
      if Enum.any?(results, &Result.failed?/1) do
        cmds ++
          [
            %{
              "command" => "mix test.lens -- --failed",
              "comment" => "rerun the failing tests"
            }
          ]
      else
        cmds
      end

    cmds =
      cmds ++
        [
          %{
            "command" => "mix test.lens -- --stale",
            "comment" => "check for stale tests"
          }
        ]

    case seed do
      n when is_integer(n) ->
        cmds ++
          [
            %{
              "command" => "mix test.lens -- --seed #{n}",
              "comment" => "reproduce this run"
            }
          ]

      :random ->
        cmds

      _ ->
        cmds
    end
  end

  defp stringify_tags(tags) when is_map(tags) do
    Map.new(tags, fn {k, v} -> {Atom.to_string(k), stringify_tag_value(v)} end)
  end
  defp stringify_tags(_), do: %{}

  defp stringify_tag_value(v) when is_atom(v) and not is_nil(v) and v != true,
    do: Atom.to_string(v)
  defp stringify_tag_value(v), do: v

  # Convert a map with atom keys to a map with string keys, recursively.
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

  # Reuse the TerminalReporter's JSON encoder. Since the existing render_json/4
  # is for a different schema, we expose a thin encode helper there.
  defp encode_via_terminal(artifact) do
    TerminalReporter.encode_json_value(artifact)
  end
end
