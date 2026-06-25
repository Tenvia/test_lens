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

  ## Agent repair artifact (2.0+)

  `mix test.lens --agent` writes `_build/test_lens/agent.json`, a
  machine-first JSON document optimized for AI coding agents that need to
  triage failing Elixir tests. It is intentionally separate from the TTY
  and HTML reports: the human-facing surfaces stay clean, while the agent
  artifact carries fingerprints, stacktrace normalization, ranked repair
  targets, and exact verification commands.
  """

  @switches [
    json: :boolean,
    json_file: :string,
    html: :boolean,
    html_file: :string,
    agent: :boolean,
    agent_file: :string,
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

    # ExUnit 1.19's --formatter flag does not forward key:value options to
    # formatter init/1, so we publish the TestLens config via the application
    # environment. The formatter reads it on init.
    Application.put_env(:test_lens, :config, config)

    # Load the consumer's ProjectConfig (.test_lens.exs) HERE, in the
    # cwd where the mix task is invoked, and publish it to the
    # application environment. Use load_or_walk/1 (not load_or_default/1)
    # so the search walks up the directory tree — necessary for
    # umbrella projects where the mix task is invoked from the umbrella
    # root but the umbrella changes cwd to the app dir (e.g.
    # apps/saastle/) before running tests. Without the walk, the
    # default read would happen from the test-process cwd (apps/saastle/)
    # where .test_lens.exs is not, and every failure would surface
    # default_impact.
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

    # Transform color: false back to no_color: true to match expected API
    opts =
      case opts do
        [color: false] -> [no_color: true]
        other -> other
      end

    # Transform invalid options from {string, value} to {atom, :invalid_option}
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
