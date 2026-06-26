defmodule Mix.Tasks.Test.Lens do
  @moduledoc """
  Wraps `mix test`, injecting the `TestLens.Formatter` alongside
  `ExUnit.CLIFormatter`. Arguments before `--` are TestLens-specific;
  arguments after `--` are passed through unchanged to `mix test`.

      mix test.lens                       # run the full suite
      mix test.lens -- --failed           # rerun only failed tests
      mix test.lens -- test/foo_test.exs  # run a single file
      mix test.lens --json -- --failed    # JSON-mode TestLens
      mix test.lens --json-file tmp/test_lens/report.json -- --failed
      mix test.lens --html                # write HTML report
      mix test.lens --html-file tmp/test_lens/report.html
      mix test.lens --agent               # write the agent repair artifact
      mix test.lens --agent-file PATH     # override the agent artifact path
      mix test.lens --snapshot            # capture OTP snapshots at failure time
      mix test.lens --snapshot-dir PATH   # directory for per-test snapshot NDJSON
      mix test.lens --advise              # write architecture advisor artifact
      mix test.lens --advise-file PATH    # override the advisor artifact path

  ## Agent repair artifact (2.0+)

  `mix test.lens --agent` writes `_build/test_lens/agent.json`, a
  machine-first JSON document optimized for AI coding agents that need to
  triage failing Elixir tests. It is intentionally separate from the TTY
  and HTML reports: the human-facing surfaces stay clean, while the agent
  artifact carries fingerprints, stacktrace normalization, ranked repair
  targets, and exact verification commands.

  ## OTP runtime snapshots (3.0+)

  `mix test.lens --snapshot` captures test-time OTP runtime context
  (supervision tree, mailbox depth, link/monitor graph, telemetry
  rollups, GenServer state hashes) at the moment a test fails. Snapshot
  data lives in the agent artifact; TTY and HTML reports are unchanged.

  ## Architecture advisor (4.0+)

  `mix test.lens --advise` writes `_build/test_lens/advice.json`, a
  separate artifact that captures static AST + supervisor topology
  findings (cross-tree calls, raw process spawns, registry naming
  issues, etc.). The advisor runs even when no test fails.
  """

  @switches [
    json: :boolean,
    json_file: :string,
    html: :boolean,
    html_file: :string,
    agent: :boolean,
    agent_file: :string,
    snapshot: :boolean,
    snapshot_dir: :string,
    advise: :boolean,
    advise_file: :string,
    color: :boolean,
    no_color: :boolean
  ]

  @aliases [j: :json]

  def run(args) do
    {parsed, passthrough, invalid} = parse(args)

    if invalid != [] do
      raise ArgumentError, "Invalid TestLens options: #{inspect(invalid)}"
    end

    config = TestLens.Config.from_option_parser(parsed)

    Application.put_env(:test_lens, :config, config)

    project_config = TestLens.ProjectConfig.load_or_walk()
    Application.put_env(:test_lens, :project_config, project_config)

    formatter_flags = [
      "--formatter",
      "ExUnit.CLIFormatter",
      "--formatter",
      "TestLens.Formatter"
    ]

    Mix.Task.run("test", formatter_flags ++ passthrough)

    :ok
  end

  @doc false
  @spec parse([String.t()]) :: {keyword(), [String.t()], [{atom(), :invalid_option}]}
  def parse(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: @switches, aliases: @aliases, return_separator: true)

    opts =
      case opts do
        [color: false] -> [no_color: true]
        other -> other
      end

    invalid =
      Enum.map(invalid, fn {key, _value} ->
        atom_key = key |> String.trim_leading("--") |> String.to_atom()
        {atom_key, :invalid_option}
      end)

    passthrough =
      case rest do
        ["--" | after_sep] -> after_sep
        other -> other
      end

    {opts, passthrough, invalid}
  end
end
