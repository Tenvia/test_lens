defmodule TestLens.TerminalReporterTest do
  use ExUnit.Case, async: true

  alias TestLens.{Config, Result, TerminalReporter}

  defp config, do: Config.defaults()

  # Helper to build Result fixtures
  defp build_result(opts) do
    name = Keyword.get(opts, :name, :"test fast")
    module = Keyword.get(opts, :module, :"MyApp.MyTest")
    time_us = Keyword.get(opts, :time_us, 100)
    status = Keyword.get(opts, :status, :passed)
    failures = Keyword.get(opts, :failures, [])
    file = Keyword.get(opts, :file, "test/foo_test.exs")

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
      tags: %{},
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

  test "render_json/4 with empty results returns JSON with test_lens_version" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "test_lens_version"
    assert bin =~ "0.1.0"
  end

  test "render_json/4 with empty results returns JSON with summary containing passed, failed, skipped, excluded, invalid, total" do
    iodata = TerminalReporter.render_json(config(), [], %{run: 0, async: nil, load: nil}, nil)
    bin = IO.iodata_to_binary(iodata)
    assert bin =~ "\"passed\":0"
    assert bin =~ "\"failed\":0"
    assert bin =~ "\"skipped\":0"
    assert bin =~ "\"excluded\":0"
    assert bin =~ "\"invalid\":0"
    assert bin =~ "\"total\":0"
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
end
