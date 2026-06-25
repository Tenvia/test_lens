defmodule TestLens.TerminalReporter do
  @moduledoc "Renders the human-readable TestLens output."
  import ExUnit.Formatter, only: [format_test_failure: 5]
  import IO.ANSI

  # Faint/dim ANSI sequence (faint isn't exported by every IO.ANSI build).
  @dim "\e[2m"
  @reset reset()

  # Visual widths. The title box and the progress meter are fixed width so
  # the output reads as a consistent column regardless of content.
  @header_width 48
  @meter_width 24

  # Unicode glyphs used for chrome. These are codepoints, not ANSI escapes,
  # so they render in --no-color mode too (only colour is stripped).
  @full_block "█"
  @light_block "░"
  @heavy_rule "━"

  # ---------------------------------------------------------------------------
  # Colour helpers. Every helper takes a `color?` boolean and returns the
  # input unchanged when it is false, so `--no-color` (or any non-tty sink)
  # produces plain text with zero ANSI escapes. IO.ANSI is fully qualified
  # because the unqualified names (red/0, green/0, ...) clash with the
  # same-named /2 helpers in this section.
  # ---------------------------------------------------------------------------

  defp yellow(t, true), do: [IO.ANSI.yellow(), t, @reset]
  defp yellow(t, false), do: t
  defp cyan(t, true), do: [IO.ANSI.cyan(), t, @reset]
  defp cyan(t, false), do: t
  defp red(t, true), do: [IO.ANSI.red(), t, @reset]
  defp red(t, false), do: t
  defp green(t, true), do: [IO.ANSI.green(), t, @reset]
  defp green(t, false), do: t
  defp blue(t, true), do: [IO.ANSI.blue(), t, @reset]
  defp blue(t, false), do: t
  defp bright(t, true), do: [IO.ANSI.bright(), t, @reset]
  defp bright(t, false), do: t
  defp dim_text(t, true), do: [@dim, t, @reset]
  defp dim_text(t, false), do: t

  # Structural chrome (box borders, rules, meter gaps) — faint when coloured.
  defp chrome(t, true), do: [@dim, t, @reset]
  defp chrome(t, false), do: t

  # Strongest emphasis: bright + red. Reserved for critical impact/severity.
  defp bright_red(t, true), do: [IO.ANSI.bright(), IO.ANSI.red(), t, @reset]
  defp bright_red(t, false), do: t

  # ---------------------------------------------------------------------------
  # Semantic helpers — colour carries meaning (severity, outcome, timing).
  # ---------------------------------------------------------------------------

  # Impact level coloured by severity. `critical` is a separate boolean on the
  # Impact struct and escalates any level to the strongest emphasis. The plain
  # text is always the level atom, so assertions on `impact:  high` still hold.
  defp impact_label(level, critical?, color?) do
    text = Atom.to_string(level)

    cond do
      critical? -> bright_red(text, color?)
      level == :high -> red(text, color?)
      level == :medium -> yellow(text, color?)
      level == :low -> blue(text, color?)
      true -> dim_text(text, color?)
    end
  end

  # One-word outcome classification, used to tint the summary banner.
  defp outcome_kind(0, 0, _skipped, 0), do: :empty
  defp outcome_kind(_passed, failed, _skipped, _total) when failed > 0, do: :fail
  defp outcome_kind(_passed, 0, skipped, _total) when skipped > 0, do: :skip
  defp outcome_kind(_passed, 0, 0, _total), do: :pass

  defp outcome_marker(:fail, color?), do: red("✗", color?)
  defp outcome_marker(:pass, color?), do: green("✓", color?)
  defp outcome_marker(:skip, color?), do: yellow("»", color?)
  defp outcome_marker(:empty, color?), do: dim_text("·", color?)

  # Compact pass/fail ratio bar. Green = pass share, red = fail share, faint =
  # remaining. Unicode blocks, so it shows in --no-color too.
  defp progress_meter(passed, failed, total, color?) do
    {pw, fw, rw} = meter_segments(passed, failed, total)

    [
      green(String.duplicate(@full_block, pw), color?),
      red(String.duplicate(@full_block, fw), color?),
      chrome(String.duplicate(@light_block, rw), color?)
    ]
  end

  defp meter_segments(passed, failed, total) do
    if total == 0 do
      {0, 0, @meter_width}
    else
      pw = round(passed / total * @meter_width)
      fw = round(failed / total * @meter_width)
      rw = max(@meter_width - pw - fw, 0)
      {pw, fw, rw}
    end
  end

  # A full-width section rule with an inline title, e.g.
  #   ━━━ Critical (1) ━━━━━━━━━━━━━━━━━━━
  # `tone` is :critical (red), :warn (yellow), or :neutral (faint).
  defp section_rule(title, tone, color?) do
    pad = max(@header_width - String.length(title) - 6, 3)

    body =
      [@heavy_rule, @heavy_rule, @heavy_rule, " ", title, " ", String.duplicate(@heavy_rule, pad)]

    tone(body, tone, color?)
  end

  defp tone(body, :critical, true), do: [IO.ANSI.red(), body, @reset]
  defp tone(body, :warn, true), do: [IO.ANSI.yellow(), body, @reset]
  defp tone(body, :neutral, true), do: [@dim, body, @reset]
  defp tone(body, _tone, false), do: body

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
    w = @header_width
    title = bright("TestLens", config.color)
    sub = cyan("Improved ExUnit output", config.color)

    # ╭─ TestLens ───────────────────────╮
    # │ Improved ExUnit output            │
    # ╰───────────────────────────────────╯
    top = [
      chrome("╭─ ", config.color),
      title,
      chrome(" " <> String.duplicate("─", w - 13) <> "╮", config.color)
    ]

    mid = [
      chrome("│ ", config.color),
      sub,
      chrome(String.duplicate(" ", w - 25) <> "│", config.color)
    ]

    bot = chrome("╰" <> String.duplicate("─", w - 2) <> "╯", config.color)

    [top, "\n", mid, "\n", bot, "\n\n"]
  end

  @spec render_summary(
          TestLens.Config.t(),
          [TestLens.Result.t()],
          map(),
          integer() | :random | nil
        ) :: IO.iodata()
  def render_summary(%TestLens.Config{} = config, results, times_us, seed \\ nil) do
    color = config.color

    passed = Enum.count(results, &TestLens.Result.passed?/1)
    failed = Enum.count(results, &TestLens.Result.failed?/1)
    skipped = Enum.count(results, &TestLens.Result.skipped?/1)
    excluded = Enum.count(results, fn r -> r.status == :excluded end)
    invalid = Enum.count(results, fn r -> r.status == :invalid end)
    total = length(results)

    meter = progress_meter(passed, failed, total, color)
    marker = outcome_marker(outcome_kind(passed, failed, skipped, total), color)

    counts =
      [
        colorize_pass(passed, color),
        colorize_fail(failed, color),
        "#{skipped} skipped",
        "#{total} total in #{format_run_time(times_us)}#{format_excluded(excluded)}#{format_invalid(invalid)}#{format_seed(seed)}"
      ]
      |> Enum.join(", ")

    # Outcome-tinted banner: a marker + the counts, with the ratio bar below.
    ["  ", marker, " ", counts, "\n", "  ", meter, "\n"]
  end

  defp colorize_pass(n, true), do: [IO.ANSI.green(), "#{n} passed", @reset]
  defp colorize_pass(n, false), do: "#{n} passed"

  defp colorize_fail(n, true), do: [IO.ANSI.red(), "#{n} failed", @reset]
  defp colorize_fail(n, false), do: "#{n} failed"

  defp format_excluded(n) when n > 0, do: ", #{n} excluded"
  defp format_excluded(_), do: ""

  defp format_invalid(n) when n > 0, do: ", #{n} invalid"
  defp format_invalid(_), do: ""

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

    # Critical first (most actionable), then Other.
    [{:critical, critical}, {:other, other}]
    |> Enum.reject(fn {_, list} -> list == [] end)
    |> Enum.map(fn {severity, secs} ->
      header = severity_rule(severity, length(secs), config.color)
      bodies = Enum.map(secs, &render_failure_block(&1, config))
      ["\n", header, "\n\n", bodies]
    end)
  end

  defp severity_rule(:critical, count, color),
    do: section_rule("Critical (#{count})", :critical, color)

  defp severity_rule(:other, count, color), do: section_rule("Other (#{count})", :warn, color)

  defp critical_failure?(%TestLens.Result{status: :invalid}), do: true

  defp critical_failure?(%TestLens.Result{failures: [{kind, _, _} | _]})
       when kind in [:exit, :throw], do: true

  defp critical_failure?(%TestLens.Result{}), do: false

  defp render_failure_block(%TestLens.Result{} = r, config) do
    color = config.color
    module_name = inspect(r.module)
    test_name = Atom.to_string(r.name)
    critical? = critical_failure?(r)

    # ⚑ for critical, ✗ for other. The icon doubles as the severity cue.
    icon = if critical?, do: critical_icon(color), else: fail_icon(color)

    # Line 1: ⚑/✗ ModuleName > test name
    line1 = ["  ", icon, " ", bright("#{module_name} > #{test_name}", color), "\n"]

    file_str = if r.file, do: r.file, else: "(unknown)"
    type_str = type_label(r)
    layer_str = TestLens.Classifier.category_label(TestLens.Classifier.classify(r.test))

    impact = TestLens.Impact.classify(r)
    area_str = impact.area || "(no area)"
    rerun_str = rerun_command(r)

    [
      line1,
      field("type", yellow(type_str, color)),
      field("layer", cyan(layer_str, color)),
      field("impact", impact_label(impact.impact, impact.critical, color)),
      field("area", dim_text(area_str, color)),
      field("file", dim_text(file_str, color)),
      field("rerun", cyan(rerun_str, color)),
      failure_body_section(r)
    ]
  end

  # Aligned label/value row: "    label:   value". Labels are padded so the
  # values line up. Keeps the `impact:\s+high` / `area:` contract intact.
  defp field(label, value) do
    ["    ", String.pad_trailing("#{label}:", 9), " ", value, "\n"]
  end

  defp critical_icon(true), do: [IO.ANSI.bright(), IO.ANSI.red(), "⚑", @reset]
  defp critical_icon(false), do: "⚑"

  defp fail_icon(true), do: [IO.ANSI.red(), "✗", @reset]
  defp fail_icon(false), do: "✗"

  defp failure_body_section(%TestLens.Result{} = r) do
    case compact_failure(r) do
      "" -> ""
      body -> ["\n", body, "\n"]
    end
  end

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

    case slow do
      [] ->
        ""

      [first | _rest] ->
        threshold = first.time_us

        lines =
          Enum.map(slow, fn r ->
            bar = slow_bar(r.time_us, threshold, config.color)
            ms = format_ms(r.time_us)
            module_name = inspect(r.module)
            test_name = Atom.to_string(r.name)
            [bar, " ", yellow(ms, config.color), "  ", module_name, " > ", test_name, "\n"]
          end)

        ["\n", section_rule("Slowest tests", :neutral, config.color), "\n\n", lines]
    end
  end

  # A 5-cell heat bar: more filled blocks the closer a test is to the slowest,
  # coloured by how hot it is (red near the max, yellow mid, blue tail).
  defp slow_bar(time_us, threshold, color?) do
    ratio = if threshold > 0, do: time_us / threshold, else: 0
    filled = max(round(ratio * 5), 1)
    blocks = String.duplicate(@full_block, filled) <> String.duplicate(@light_block, 5 - filled)
    heat = if(ratio >= 0.8, do: :red, else: if(ratio >= 0.4, do: :yellow, else: :blue))
    heat_color(blocks, heat, color?)
  end

  defp heat_color(t, :red, true), do: [IO.ANSI.red(), t, @reset]
  defp heat_color(t, :yellow, true), do: [IO.ANSI.yellow(), t, @reset]
  defp heat_color(t, :blue, true), do: [IO.ANSI.blue(), t, @reset]
  defp heat_color(t, _heat, false), do: t

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

    # Order: failed (if any), stale, seed. Most actionable first.
    commands =
      [
        {failures != [], "mix test.lens -- --failed", "rerun the failing tests"},
        {true, "mix test.lens -- --stale", "check for stale tests"},
        {is_integer(seed), "mix test.lens -- --seed #{seed}", "reproduce this run"}
      ]
      |> Enum.filter(fn {show?, _, _} -> show? end)
      |> Enum.map(fn {_, cmd, comment} -> command(cmd, comment, color) end)

    if commands == [] do
      ""
    else
      ["\n", section_rule("Next", :neutral, color), "\n\n", commands]
    end
  end

  defp command(cmd, comment, color) do
    ["  $ ", bright(cmd, color), "  ", dim_text("# #{comment}", color), "\n"]
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
