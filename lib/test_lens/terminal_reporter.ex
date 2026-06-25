defmodule TestLens.TerminalReporter do
  @moduledoc "Renders the human-readable TestLens output."
  import ExUnit.Formatter, only: [format_test_failure: 5]
  import IO.ANSI

  # Dim ANSI sequence (not available in all IO.ANSI versions)
  @dim "\e[2m"
  @reset reset()

  # All colorize helpers take a `color?` boolean. When false, they return
  # the input unchanged so `--no-color` (or any non-tty sink) produces
  # plain ASCII. Inside the helpers we use fully-qualified IO.ANSI calls
  # because the unqualified names (red/0, green/0, ...) would shadow
  # the same-named /2 helpers in this module.
  defp yellow(t, true), do: [IO.ANSI.yellow(), t, @reset]
  defp yellow(t, false), do: t
  defp cyan(t, true), do: [IO.ANSI.cyan(), t, @reset]
  defp cyan(t, false), do: t
  defp bright(t, true), do: [IO.ANSI.bright(), t, @reset]
  defp bright(t, false), do: t
  defp dim_text(t, true), do: [@dim, t, @reset]
  defp dim_text(t, false), do: t

  @spec render(TestLens.Config.t(), [TestLens.Result.t()], map(), integer() | :random | nil) ::
          IO.iodata()
  def render(config, results, times_us), do: render(config, results, times_us, nil)

  def render(%TestLens.Config{format: :json} = config, results, times_us, seed) do
    [render_json(config, results, times_us, seed), "\n"]
  end

  def render(%TestLens.Config{} = config, results, times_us, seed) do
    failures = Enum.filter(results, &TestLens.Result.failed?/1)
    slow = render_slow_tests(config, results)

    [
      render_header(config),
      render_summary(config, results, times_us, seed),
      render_failures(config, failures),
      slow,
      render_next_commands(config, failures, seed)
    ]
  end

  @spec render_header(TestLens.Config.t()) :: IO.iodata()
  def render_header(%TestLens.Config{} = config) do
    label = bright(["== TestLens =="], config.color)
    sub = cyan("Improved ExUnit output", config.color)
    [label, "\n", sub, "\n\n"]
  end

  @spec render_summary(
          TestLens.Config.t(),
          [TestLens.Result.t()],
          map(),
          integer() | :random | nil
        ) :: IO.iodata()
  def render_summary(%TestLens.Config{} = config, results, times_us, seed \\ nil) do
    passed = Enum.count(results, &TestLens.Result.passed?/1)
    failed = Enum.count(results, &TestLens.Result.failed?/1)
    skipped = Enum.count(results, &TestLens.Result.skipped?/1)
    excluded = Enum.count(results, fn r -> r.status == :excluded end)
    invalid = Enum.count(results, fn r -> r.status == :invalid end)
    total = length(results)

    passed_str = colorize_pass(passed, config.color)
    failed_str = colorize_fail(failed, config.color)
    skipped_str = "#{skipped} skipped"
    excluded_str = if excluded > 0, do: ", #{excluded} excluded", else: ""
    invalid_str = if invalid > 0, do: ", #{invalid} invalid", else: ""
    time_str = format_run_time(times_us)
    seed_str = format_seed(seed)

    summary =
      Enum.join(
        [
          passed_str,
          failed_str,
          skipped_str,
          "#{total} total in #{time_str}#{excluded_str}#{invalid_str}#{seed_str}"
        ],
        ", "
      )

    [summary, "\n"]
  end

  defp colorize_pass(n, true), do: [IO.ANSI.green(), "#{n} passed", @reset]
  defp colorize_pass(n, false), do: "#{n} passed"

  defp colorize_fail(n, true), do: [IO.ANSI.red(), "#{n} failed", @reset]
  defp colorize_fail(n, false), do: "#{n} failed"

  defp format_seed(nil), do: ""
  defp format_seed(:random), do: " (seed: random)"
  defp format_seed(n) when is_integer(n), do: " (seed: #{n})"

  defp format_run_time(times_us) do
    run_us = Map.get(times_us, :run, 0)
    seconds = run_us / 1_000_000

    if seconds < 1 do
      ms = run_us / 1000
      :io_lib.format("~.1fms", [ms]) |> IO.iodata_to_binary()
    else
      :io_lib.format("~.1fs", [seconds]) |> IO.iodata_to_binary()
    end
  end

  @spec render_failures(TestLens.Config.t(), [TestLens.Result.t()]) :: IO.iodata()
  def render_failures(%TestLens.Config{} = _config, []) do
    ""
  end

  def render_failures(%TestLens.Config{} = config, failures) do
    {critical, other} = Enum.split_with(failures, &critical_failure?/1)

    sections = []

    sections =
      if critical != [] do
        [{:critical, critical} | sections]
      else
        sections
      end

    sections =
      if other != [] do
        [{:other, other} | sections]
      else
        sections
      end

    Enum.map(sections, fn {severity, secs} ->
      header = severity_header(severity, length(secs), config.color)
      bodies = Enum.map(secs, &render_failure_block(&1, config))
      [header, "\n", bodies, "\n"]
    end)
  end

  defp severity_header(:critical, count, color) do
    label = bright("── Critical (#{count}) ──", color)
    ["\n", label, "\n"]
  end

  defp severity_header(:other, count, color) do
    label = bright("── Other (#{count}) ──", color)
    ["\n", label, "\n"]
  end

  defp critical_failure?(%TestLens.Result{status: :invalid}), do: true

  defp critical_failure?(%TestLens.Result{failures: [{kind, _, _} | _]})
       when kind in [:exit, :throw], do: true

  defp critical_failure?(%TestLens.Result{}), do: false

  defp render_failure_block(%TestLens.Result{} = r, config) do
    color = config.color
    module_name = inspect(r.module)
    test_name = Atom.to_string(r.name)

    # Line 1: ✗ ModuleName > test "name"
    line1 = [colorize_fail_icon(color), " ", bright("#{module_name} > #{test_name}", color), "\n"]

    # Line 2: file
    file_str = if r.file, do: r.file, else: "(unknown)"
    line2 = ["    file:    ", dim_text(file_str, color), "\n"]

    # Line 3: type
    type_label = type_label(r)
    line3 = ["    type:    ", yellow(type_label, color), "\n"]

    # Line 4: layer
    layer_label = TestLens.Classifier.category_label(TestLens.Classifier.classify(r.test))
    line4 = ["    layer:   ", cyan(layer_label, color), "\n"]

    # Line 5: impact + area — populated by TestLens.Impact, which loads
    # the consumer's .test_lens.exs via ProjectConfig.load_or_default/0
    # and matches the test's file path against the configured areas.
    impact = TestLens.Impact.classify(r)
    impact_label = Atom.to_string(impact.impact)
    area_label = impact.area || "(no area)"
    line5 = ["    impact:  ", yellow(impact_label, color), "\n"]
    line5_area = ["    area:    ", dim_text(area_label, color), "\n"]

    # Line 6: rerun
    rerun_cmd = rerun_command(r)
    line6 = ["    rerun:   ", cyan(rerun_cmd, color), "\n"]

    # Blank line + raw failure body
    failure_body = compact_failure(r)

    body_section =
      if failure_body != "" do
        ["\n", failure_body, "\n"]
      else
        ""
      end

    [line1, line2, line3, line4, line5, line5_area, line6, body_section, "\n"]
  end

  defp colorize_fail_icon(true), do: [IO.ANSI.red(), "✗", @reset]
  defp colorize_fail_icon(false), do: "✗"

  defp type_label(%TestLens.Result{status: :invalid}) do
    "invalid test"
  end

  defp type_label(%TestLens.Result{failures: [{kind, _, _} | _]}) do
    case kind do
      :error -> "assertion error"
      :exit -> "process exit"
      :throw -> "explicit throw"
      _ -> "unknown"
    end
  end

  defp type_label(%TestLens.Result{}), do: "unknown"

  defp rerun_command(%TestLens.Result{}), do: "mix test.lens -- --failed"

  # Safe compact failure body
  defp compact_failure(%TestLens.Result{} = r) do
    try do
      format_test_failure(r.test, 1, r.failures, 1, nil)
    rescue
      _ -> ""
    end
  end

  @spec render_slow_tests(TestLens.Config.t(), [TestLens.Result.t()]) :: IO.iodata()
  def render_slow_tests(%TestLens.Config{} = _config, []) do
    ""
  end

  def render_slow_tests(%TestLens.Config{} = config, results) do
    slow =
      results
      |> Enum.filter(fn r -> r.time_us > 0 end)
      |> Enum.sort_by(& &1.time_us, :desc)
      |> Enum.take(5)

    if slow == [] do
      ""
    else
      header = cyan("── Slowest tests ──", config.color)

      lines =
        Enum.map(slow, fn r ->
          ms = format_ms(r.time_us)
          module_name = inspect(r.module)
          test_name = Atom.to_string(r.name)
          [yellow(ms, config.color), "  ", module_name, " > ", test_name, "\n"]
        end)

      ["\n", header, "\n", lines]
    end
  end

  defp format_ms(time_us) do
    ms = time_us / 1000.0
    :io_lib.format("~8.1fms", [ms]) |> IO.iodata_to_binary()
  end

  @spec render_next_commands(
          TestLens.Config.t(),
          [TestLens.Result.t()],
          integer() | :random | nil
        ) :: IO.iodata()
  def render_next_commands(%TestLens.Config{} = config, failures, seed) do
    color = config.color

    header = bright("── Next commands ──", color)

    commands =
      []
      |> prepend_if(true, [
        "  $ ",
        bright("mix test.lens -- --stale", color),
        dim_text("  # check for stale tests", color),
        "\n"
      ])
      |> prepend_if(failures != [], [
        "  $ ",
        bright("mix test.lens -- --failed", color),
        dim_text("  # rerun the failing tests", color),
        "\n"
      ])
      |> prepend_if(is_integer(seed), [
        "  $ ",
        bright("mix test.lens -- --seed #{seed}", color),
        dim_text("  # reproduce this run", color),
        "\n"
      ])

    if commands == [] do
      ""
    else
      ["\n", header, "\n", commands]
    end
  end

  defp prepend_if(list, condition, item) do
    if condition, do: [item | list], else: list
  end

  @spec render_json(TestLens.Config.t(), [TestLens.Result.t()], map(), integer() | :random | nil) ::
          IO.iodata()
  def render_json(%TestLens.Config{} = _config, results, times_us, seed \\ nil) do
    passed = Enum.count(results, &TestLens.Result.passed?/1)
    failed = Enum.count(results, &TestLens.Result.failed?/1)
    skipped = Enum.count(results, &TestLens.Result.skipped?/1)
    excluded = Enum.count(results, fn r -> r.status == :excluded end)
    invalid = Enum.count(results, fn r -> r.status == :invalid end)
    total = length(results)

    failure_entries =
      results
      |> Enum.filter(&TestLens.Result.failed?/1)
      |> Enum.map(&failure_to_json/1)

    slow =
      results
      |> Enum.filter(fn r -> r.time_us > 0 end)
      |> Enum.sort_by(& &1.time_us, :desc)
      |> Enum.take(5)
      |> Enum.map(fn r ->
        %{
          "name" => Atom.to_string(r.name),
          "module" => inspect(r.module),
          "file" => r.file,
          "time_us" => r.time_us
        }
      end)

    next_commands =
      build_next_commands_json(seed, failed > 0)

    seed_value =
      cond do
        is_integer(seed) -> seed
        seed == :random -> "random"
        true -> nil
      end

    json_map = %{
      "test_lens_version" => TestLens.version(),
      "summary" => %{
        "passed" => passed,
        "failed" => failed,
        "skipped" => skipped,
        "excluded" => excluded,
        "invalid" => invalid,
        "total" => total,
        "times_us" => times_us
      },
      "failures" => failure_entries,
      "slow" => slow,
      "next_commands" => next_commands,
      "seed" => seed_value
    }

    [encode_json(json_map)]
  end

  defp build_next_commands_json(_seed, _has_failures = false) do
    [%{"command" => "mix test.lens -- --stale", "comment" => "check for stale tests"}]
  end

  defp build_next_commands_json(_seed, _has_failures = true) do
    [
      %{"command" => "mix test.lens -- --stale", "comment" => "check for stale tests"},
      %{"command" => "mix test.lens -- --failed", "comment" => "rerun the failing tests"}
    ]
  end

  defp failure_to_json(%TestLens.Result{} = f) do
    {severity, kind} = failure_severity_and_kind(f)

    layer = TestLens.Classifier.category_label(TestLens.Classifier.classify(f.test))

    # Surface the real Impact classification (area, impact, user_facing,
    # critical, reason) from the consumer's .test_lens.exs. The previous
    # implementation hardcoded "impact" => "unknown" which made the JSON
    # output useless for downstream tooling that wants to sort failures
    # by impact or filter on critical. Mirrors the human-output branch
    # (which was wired in the previous fix) and the failure_entry/1
    # contract in TestLens.JSONReport.
    impact =
      f
      |> TestLens.Impact.classify()
      |> Map.from_struct()
      |> stringify_keys()

    %{
      "severity" => Atom.to_string(severity),
      "kind" => Atom.to_string(kind),
      "layer" => layer,
      "impact" => impact,
      "module" => inspect(f.module),
      "name" => Atom.to_string(f.name),
      "file" => f.file
    }
  end

  defp failure_severity_and_kind(%TestLens.Result{status: :invalid}) do
    {:critical, :invalid}
  end

  defp failure_severity_and_kind(%TestLens.Result{failures: [{kind, _, _} | _]}) do
    severity = if kind in [:exit, :throw], do: :critical, else: :other
    {severity, kind}
  end

  defp failure_severity_and_kind(%TestLens.Result{}) do
    {:other, :unknown}
  end

  @doc """
  Encodes an arbitrary Elixir value (map, list, scalar) as a JSON string.
  Public so other modules (e.g. TestLens.JSONReport) can reuse the
  hand-rolled encoder without depending on a result struct.
  """
  @spec encode_json_value(term()) :: String.t()
  def encode_json_value(value) do
    encode_json(value) |> IO.iodata_to_binary()
  end

  # Convert a map with atom keys to a map with string keys, recursively.
  # Mirrors TestLens.JSONReport.stringify_keys/1. Duplicated here rather
  # than promoted to a shared module because the two implementations have
  # different lifecycles and the public surface of this module is large
  # already; consolidating is a separate refactor.
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

  # Tiny JSON encoder covering only the shapes we emit (string keys, scalars,
  # nested maps, lists). No external dependency.
  defp encode_json(value) do
    case value do
      nil -> "null"
      true -> "true"
      false -> "false"
      n when is_integer(n) -> Integer.to_string(n)
      n when is_float(n) -> Float.to_string(n)
      s when is_binary(s) -> encode_string(s)
      m when is_map(m) -> encode_object(m)
      l when is_list(l) -> encode_array(l)
      a when is_atom(a) -> encode_string(Atom.to_string(a))
    end
  end

  defp encode_object(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> [encode_string(to_string(k)), ":", encode_json(v)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp encode_array(list) do
    items = Enum.map(list, &encode_json/1) |> Enum.intersperse(",")
    ["[", items, "]"]
  end

  defp encode_string(s) do
    escaped =
      s
      |> :unicode.characters_to_binary()
      |> escape_json_string()

    ["\"", escaped, "\""]
  end

  defp escape_json_string(<<>>), do: <<>>

  defp escape_json_string(<<?\\, rest::binary>>) do
    [?\\, ?\\ | escape_json_string(rest)]
  end

  defp escape_json_string(<<?\", rest::binary>>) do
    [?\\, ?" | escape_json_string(rest)]
  end

  defp escape_json_string(<<?\n, rest::binary>>) do
    [?\\, ?n | escape_json_string(rest)]
  end

  defp escape_json_string(<<?\r, rest::binary>>) do
    [?\\, ?r | escape_json_string(rest)]
  end

  defp escape_json_string(<<?\t, rest::binary>>) do
    [?\\, ?t | escape_json_string(rest)]
  end

  defp escape_json_string(<<?\b, rest::binary>>) do
    [?\\, ?b | escape_json_string(rest)]
  end

  defp escape_json_string(<<?\f, rest::binary>>) do
    [?\\, ?f | escape_json_string(rest)]
  end

  defp escape_json_string(<<c, rest::binary>>) when c < 0x20 do
    hex = :io_lib.format("\\u~4.16.0b", [c]) |> IO.iodata_to_binary()
    [hex | escape_json_string(rest)]
  end

  defp escape_json_string(<<c, rest::binary>>) do
    [c | escape_json_string(rest)]
  end
end
