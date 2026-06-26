defmodule TestLens.TerminalReporterTest do
  # async: false — the Impact wiring tests below temporarily change the
  # VM-wide cwd with File.cd!/1 so TestLens.Impact.classify/1 can load a real
  # .test_lens.exs. cwd is global process state, not test-process-local; with
  # async: true this can race the parallel test loader/compiler and surface as
  # {:error, :enoent} while another test file is being required on CI.
  use ExUnit.Case, async: false

  alias TestLens.{Config, JSONReport, Result, TerminalReporter}

  defp config, do: Config.defaults()

  # Helper to build Result fixtures
  defp build_result(opts) do
    name = Keyword.get(opts, :name, :"test fast")
    module = Keyword.get(opts, :module, :"MyApp.MyTest")
    time_us = Keyword.get(opts, :time_us, 100)
    status = Keyword.get(opts, :status, :passed)
    failures = Keyword.get(opts, :failures, [])
    file = Keyword.get(opts, :file, "test/foo_test.exs")
    tags = Keyword.get(opts, :tags, [])

    state =
      case status do
        :passed -> nil
        :failed -> {:failed, failures}
        :skipped -> {:skipped, "wip"}
        :excluded -> {:excluded, :skip_on_ci}
        :invalid -> {:invalid, "bad test"}
      end

    %Result{
      test: %ExUnit.Test{
        module: module,
        name: name,
        state: state,
        time: time_us,
        tags: %{},
        logs: []
      },
      status: status,
      time_us: time_us,
      failures: failures,
      tags: Map.new(tags, &{&1, true}),
      module: module,
      name: name,
      file: file,
      line: nil
    }
  end

  # Result with :error kind failure
  defp error_result do
    build_result(
      name: :"test error",
      module: :"MyApp.ErrorTest",
      status: :failed,
      failures: [{:error, %RuntimeError{message: "boom"}, []}]
    )
  end

  # Result with :exit kind failure (Critical)
  defp exit_result do
    build_result(
      name: :"test exit",
      module: :"MyApp.ExitTest",
      status: :failed,
      failures: [{:exit, :killed, []}]
    )
  end

  # Result with :throw kind failure (Critical)
  defp throw_result do
    build_result(
      name: :"test throw",
      module: :"MyApp.ThrowTest",
      status: :failed,
      failures: [{:throw, :badarg, []}]
    )
  end

  # Slow result for testing slow tests section
  defp slow_result do
    build_result(
      name: :"test slow",
      module: :"MyApp.SlowTest",
      status: :passed,
      time_us: 145_200
    )
  end

  test "render_header/1 returns non-empty iodata containing TestLens" do
    iodata = TerminalReporter.render_header(config())
    assert IO.iodata_to_binary(iodata) =~ "TestLens"
  end

  test "render_summary/4 with empty results contains 0 and contains a time string" do
    iodata = TerminalReporter.render_summary(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "0"
    assert bin =~ "total in"
  end

  test "render_summary/4 with an integer seed contains seed: N" do
    iodata =
      TerminalReporter.render_summary(config(), [], %{run: 0, async: nil, load: nil}, 12345)

    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "seed: 12345"
  end

  test "render_summary/4 with seed = :random contains random" do
    iodata =
      TerminalReporter.render_summary(config(), [], %{run: 0, async: nil, load: nil}, :random)

    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "seed: random"
  end

  test "render_summary/4 with seed = nil does NOT contain seed" do
    iodata = TerminalReporter.render_summary(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "seed"
  end

  test "render_summary/4 with one failed result includes failed" do
    result = error_result()

    iodata =
      TerminalReporter.render_summary(config(), [result], %{run: 0, async: nil, load: nil}, nil)

    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "failed"
  end

  test "render_failures/2 with empty failures returns empty iodata" do
    iodata = TerminalReporter.render_failures(config(), [])
    assert IO.iodata_to_binary(iodata) == ""
  end

  test "render_failures/2 with one failure contains module name" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "MyApp.ErrorTest"
  end

  test "render_failures/2 with one failure contains test name atom" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "test error"
  end

  test "render_failures/2 with one failure contains file path" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "test/foo_test.exs"
  end

  test "render_failures/2 with one failure contains type:" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "type:"
  end

  test "render_failures/2 with one failure contains layer:" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "layer:"
  end

  test "render_failures/2 with one failure contains impact:" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "impact:"
  end

  test "render_failures/2 with one failure contains rerun:" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "rerun:"
  end

  test "render_failures/2 with one failure contains mix test.lens and --failed" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "mix test.lens"
    assert bin =~ "--failed"
  end

  test "render_failures/2 groups by severity: exit kind renders Critical" do
    result = exit_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "Critical"
  end

  test "render_failures/2 groups by severity: throw kind renders Critical" do
    result = throw_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "Critical"
  end

  test "render_failures/2 with only error kind failures renders Other" do
    result = error_result()
    iodata = TerminalReporter.render_failures(config(), [result])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "Other"
  end

  test "render_slow_tests/2 with empty list returns empty" do
    iodata = TerminalReporter.render_slow_tests(config(), [])
    assert IO.iodata_to_binary(iodata) == ""
  end

  test "render_slow_tests/2 with results includes the slowest test's name" do
    slow = slow_result()
    fast = build_result(time_us: 100, name: :"test fast")
    iodata = TerminalReporter.render_slow_tests(config(), [fast, slow])
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "test slow"
  end

  test "render_slow_tests/2 caps at 5 tests" do
    results =
      for i <- 1..10 do
        build_result(name: :"test_#{i}", time_us: i * 10_000)
      end

    iodata = TerminalReporter.render_slow_tests(config(), results)
    bin = IO.iodata_to_binary(iodata)

    # Should have 5 entries (top 5: test_10, test_9, test_8, test_7, test_6)
    assert bin =~ "test_10"
    # The 6th slowest (test_5 at 50ms) should NOT be present
    refute bin =~ "test_5"
  end

  test "render_next_commands/3 always includes --stale" do
    iodata = TerminalReporter.render_next_commands(config(), [], nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "--stale"
  end

  test "render_next_commands/3 with failures includes --failed" do
    result = error_result()
    iodata = TerminalReporter.render_next_commands(config(), [result], nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "--failed"
  end

  test "render_next_commands/3 with seed = 42 includes --seed 42" do
    iodata = TerminalReporter.render_next_commands(config(), [], 42)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "--seed 42"
  end

  test "render_next_commands/3 with seed = :random does NOT include --seed" do
    iodata = TerminalReporter.render_next_commands(config(), [], :random)
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "--seed"
  end

  test "render_next_commands/3 with seed = nil does NOT include --seed" do
    iodata = TerminalReporter.render_next_commands(config(), [], nil)
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "--seed"
  end

  test "render/4 with empty results includes header + summary, no failures, no slow section" do
    iodata = TerminalReporter.render(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "TestLens"
    assert bin =~ "0 passed"
    # No failures section for empty results
    refute bin =~ "Critical"
    refute bin =~ "Other"
    # No slow section when no slow tests
    refute bin =~ "Slowest tests"
  end

  test "render/4 with failures includes the failure block" do
    result = error_result()
    iodata = TerminalReporter.render(config(), [result], %{run: 1000, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "mix test.lens"
    assert bin =~ "--failed"
  end

  test "render/4 with seed = 42 includes seed: 42 in the rendered output" do
    iodata = TerminalReporter.render(config(), [], %{run: 0, async: nil, load: nil}, 42)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "seed: 42"
  end

  test "render_json/4 with empty results returns JSON with schema_version and test_lens_version" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "\"schema_version\":\"1.0\""
    assert bin =~ "test_lens_version"
    assert bin =~ TestLens.version()
  end

  test "render_json/4 with empty results returns JSON totals containing passed, failed, skipped, excluded, invalid, tests" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "\"passed\":0"
    assert bin =~ "\"failed\":0"
    assert bin =~ "\"skipped\":0"
    assert bin =~ "\"excluded\":0"
    assert bin =~ "\"invalid\":0"
    assert bin =~ "\"tests\":0"
  end

  test "render_json/4 with empty results returns JSON with times_us" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 123, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "times_us"
  end

  test "render_json/4 with empty results returns JSON with empty failures array" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "\"failures\":[]"
  end

  test "render_json/4 with empty results returns JSON with empty slow array" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "\"slow\":[]"
  end

  test "render_json/4 with empty results returns JSON with next_commands array" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "next_commands"
  end

  test "render_json/4 with empty results returns JSON with seed field" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "seed"
  end

  test "render_json/4 delegates to TestLens.JSONReport (single source of truth)" do
    results = [error_result()]
    times_us = %{run: 1000, async: nil, load: nil}
    seed = 42

    via_terminal =
      IO.iodata_to_binary(TerminalReporter.render_json(config(), results, times_us, seed))

    via_report = JSONReport.encode(JSONReport.build(results, times_us, seed))

    left = Jason.decode!(via_terminal)
    right = Jason.decode!(via_report)

    # `timestamp` is generated at build time, so it differs between the two
    # calls. Strip it before comparing structural equivalence.
    left_no_ts = Map.delete(left, "timestamp")
    right_no_ts = Map.delete(right, "timestamp")

    assert left_no_ts == right_no_ts
  end

  # ---------------------------------------------------------------------------
  # JSON failure impact wiring (regression for second-half of PR #3)
  # ---------------------------------------------------------------------------

  test "render_json/4 with a failed result: impact is a nested object, not the hardcoded string \"unknown\"" do
    iodata =
      TerminalReporter.render_json(
        config(),
        [error_result()],
        %{run: 1000, async: nil, load: nil},
        nil
      )

    bin = IO.iodata_to_binary(iodata)
    decoded = Jason.decode!(bin)
    [%{"impact" => impact, "module" => _module, "name" => _name}] = decoded["failures"]

    # Pre-fix bug: impact was the literal string "unknown" regardless of config.
    # Post-fix: impact is a map produced by TestLens.Impact.classify/1.
    refute impact == "unknown",
           "render_json/4 must not hardcode impact=\"unknown\"; " <>
             "it should call TestLens.Impact.classify/1 and surface the result."

    assert is_map(impact),
           "impact must be a map (TestLens.Impact struct as a map), got: #{inspect(impact)}"

    # The Impact struct has these fields. After stringify_keys/Map.from_struct,
    # they appear as string keys in the JSON.
    for key <- ~w(area impact user_facing critical reason) do
      assert Map.has_key?(impact, key),
             "impact map must contain key #{inspect(key)}, got: #{inspect(impact)}"
    end
  end

  test "render_json/4 with a failed result: file path is preserved in the failure entry" do
    iodata =
      TerminalReporter.render_json(
        config(),
        [error_result()],
        %{run: 1000, async: nil, load: nil},
        nil
      )

    bin = IO.iodata_to_binary(iodata)
    decoded = Jason.decode!(bin)
    [%{"file" => file}] = decoded["failures"]
    assert file == "test/foo_test.exs"
  end

  test "render_json/4 with a failed result and no .test_lens.exs: impact falls back to default_impact (not a hardcoded string)" do
    # The test_lens project itself has no .test_lens.exs (it's the library,
    # not a consumer). So Impact.classify/1 returns the default_impact
    # struct: area: nil, impact: :none, user_facing: false, critical: false.
    # The wiring must still surface this as a map, not the literal
    # string "unknown".
    iodata =
      TerminalReporter.render_json(
        config(),
        [error_result()],
        %{run: 1000, async: nil, load: nil},
        nil
      )

    bin = IO.iodata_to_binary(iodata)
    decoded = Jason.decode!(bin)
    [%{"impact" => impact}] = decoded["failures"]

    assert is_map(impact)
    assert impact["area"] == nil
    assert impact["impact"] == "none"
    assert impact["user_facing"] == false
    assert impact["critical"] == false
    assert impact["reason"] == "no matching area or tag"
  end

  # ---------------------------------------------------------------------------
  # --no-color regression
  # ---------------------------------------------------------------------------

  test "render/4 with color: false produces no ANSI escape codes (header + summary)" do
    cfg = %Config{color: false}
    iodata = TerminalReporter.render(cfg, [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "\e[", "TTY output must contain no ANSI escapes when color is false"
  end

  test "render_header/1 with color: false contains no ANSI escapes" do
    cfg = %Config{color: false}
    iodata = TerminalReporter.render_header(cfg)
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "\e["
  end

  test "render_failures/2 with color: false contains no ANSI escapes" do
    cfg = %Config{color: false}
    iodata = TerminalReporter.render_failures(cfg, [error_result()])
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "\e["
  end

  test "render_slow_tests/2 with color: false contains no ANSI escapes" do
    cfg = %Config{color: false}
    iodata = TerminalReporter.render_slow_tests(cfg, [slow_result()])
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "\e["
  end

  test "render_next_commands/3 with color: false contains no ANSI escapes" do
    cfg = %Config{color: false}
    iodata = TerminalReporter.render_next_commands(cfg, [error_result()], 42)
    bin = IO.iodata_to_binary(iodata)
    refute bin =~ "\e["
  end

  # ---------------------------------------------------------------------------
  # render_failures/2 wires Impact.classify/1 — the consumer's .test_lens.exs
  # populates `impact:` and `area:`. These tests use a real on-disk
  # .test_lens.exs because Impact.classify/1 reads it from the CWD; the
  # terminal_reporter itself never sees the ProjectConfig.
  # ---------------------------------------------------------------------------

  describe "render_failures/2 with TestLens.Impact wiring" do
    setup do
      dir = Path.join(System.tmp_dir!(), "test_lens_impact_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, ".test_lens.exs"), """
      [
        project: "TestApp",
        areas: %{
          "test/known/" => [label: "KnownArea", impact: :high, user_facing: true]
        },
        critical_tags: [:payment]
      ]
      """)

      prev_cwd = File.cwd!()
      File.cd!(dir)

      on_exit(fn ->
        File.cd!(prev_cwd)
        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "render_failures/2 populates impact from the project config (not 'unknown')" do
      cfg = %Config{color: false}

      r =
        build_result(
          file: "test/known/example_test.exs",
          state: {:failed, []},
          status: :failed,
          failures: [{:error, %RuntimeError{message: "boom"}, []}]
        )

      iodata = TerminalReporter.render_failures(cfg, [r])
      bin = IO.iodata_to_binary(iodata)

      refute bin =~ "impact:  unknown",
             "regression: impact must come from TestLens.Impact.classify, not the v0.1.0 placeholder"

      assert bin =~ ~r/impact:\s+high/,
             "expected impact level :high from .test_lens.exs, got: #{bin}"
    end

    test "render_failures/2 shows the area label from the project config" do
      cfg = %Config{color: false}

      r =
        build_result(
          file: "test/known/example_test.exs",
          state: {:failed, []},
          status: :failed,
          failures: [{:error, %RuntimeError{message: "boom"}, []}]
        )

      iodata = TerminalReporter.render_failures(cfg, [r])
      bin = IO.iodata_to_binary(iodata)

      assert bin =~ "area:"
      assert bin =~ "KnownArea"
    end

    test "render_failures/2 with no matching area shows impact: none and area: (no area)" do
      cfg = %Config{color: false}

      # File path doesn't match any prefix in the .test_lens.exs above.
      r =
        build_result(
          file: "test/unknown/example_test.exs",
          state: {:failed, []},
          status: :failed,
          failures: [{:error, %RuntimeError{message: "boom"}, []}]
        )

      iodata = TerminalReporter.render_failures(cfg, [r])
      bin = IO.iodata_to_binary(iodata)

      assert bin =~ ~r/impact:\s+none/,
             "expected default impact :none for unmatched path, got: #{bin}"

      assert bin =~ "(no area)",
             "expected '(no area)' placeholder for unmatched path, got: #{bin}"
    end
  end
end
