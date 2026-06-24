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
  """

  @switches [
    json: :boolean,
    json_file: :string,
    html: :boolean,
    html_file: :string,
    color: :boolean,
    no_color: :boolean,
    impact: :boolean,
    rerun: :boolean
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
