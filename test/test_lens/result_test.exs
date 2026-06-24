defmodule TestLens.ResultTest do
  @moduledoc """
  Tests for `TestLens.Result` — the normalised per-test record built from
  raw ExUnit events. These exercise the event-normalisation contract that
  the formatter relies on; nothing here touches GenServer state.
  """
  use ExUnit.Case, async: true

  alias TestLens.Result

  # ---------------------------------------------------------------------------
  # Fixtures: hand-built ExUnit.Test and ExUnit.TestModule structs.
  # We avoid real ExUnit.Case here because the normalisation contract
  # should hold for any ExUnit.Test, not only ones produced by a case
  # template.
  # ---------------------------------------------------------------------------

  defp build_test(opts \\ []) do
    %ExUnit.Test{
      name: Keyword.get(opts, :name, :"test example"),
      module: Keyword.get(opts, :module, :"MyAppWeb.UserControllerTest"),
      state: Keyword.get(opts, :state, nil),
      time: Keyword.get(opts, :time, 1_000),
      tags: Keyword.get(opts, :tags, %{}),
      logs: []
    }
  end

  defp build_test_module(opts \\ []) do
    %ExUnit.TestModule{
      name: Keyword.get(opts, :name, :"MyAppWeb.UserControllerTest"),
      file: Keyword.get(opts, :file, "test/myapp_web/user_controller_test.exs"),
      state: Keyword.get(opts, :state, nil),
      tags: %{}
    }
  end

  # Minimal Result struct for predicate tests. Result uses @enforce_keys,
  # so a plain `%Result{}` is rejected; we still want each test to be able
  # to focus on a single field, so this helper fills in sensible defaults.
  defp result_with(status) do
    %Result{
      test: nil,
      status: status,
      time_us: 0,
      failures: [],
      tags: %{},
      module: M1,
      name: :some_test,
      file: nil,
      line: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Status derivation
  # ---------------------------------------------------------------------------

  test "new/1 with state: nil normalises to :passed" do
    r = Result.new(build_test(state: nil))
    assert r.status == :passed
    assert r.failures == []
  end

  test "new/1 with state: {:failed, failures} normalises to :failed and preserves failures" do
    failures = [{:error, %RuntimeError{message: "boom"}, []}]
    r = Result.new(build_test(state: {:failed, failures}))
    assert r.status == :failed
    # Raw failures are preserved verbatim for later rendering.
    assert r.failures == failures
    assert match?([{:error, %RuntimeError{}, _}], r.failures)
  end

  test "new/1 with state: {:skipped, reason} normalises to :skipped" do
    r = Result.new(build_test(state: {:skipped, "not yet"}))
    assert r.status == :skipped
    assert r.failures == []
  end

  test "new/1 with state: {:excluded, reason} normalises to :excluded" do
    r = Result.new(build_test(state: {:excluded, :skip_on_ci}))
    assert r.status == :excluded
    assert r.failures == []
  end

  test "new/1 with state: {:invalid, test_module} normalises to :invalid" do
    r = Result.new(build_test(state: {:invalid, build_test_module()}))
    assert r.status == :invalid
  end

  test "new/1 with unknown state falls back to :passed" do
    r = Result.new(build_test(state: :weird_thing))
    assert r.status == :passed
    assert r.failures == []
  end

  # ---------------------------------------------------------------------------
  # File / line derivation from TestModule
  # ---------------------------------------------------------------------------

  test "new/2 with a TestModule struct extracts file" do
    r = Result.new(build_test(), build_test_module(file: "test/foo_test.exs"))
    assert r.file == "test/foo_test.exs"
  end

  test "new/2 with no TestModule yields nil file" do
    r = Result.new(build_test())
    assert r.file == nil
  end

  test "new/2 with a TestModule that has no file still yields nil" do
    r = Result.new(build_test(), build_test_module(file: nil))
    assert r.file == nil
  end

  test "line is always nil (ExUnit.TestModule has no :line field)" do
    r1 = Result.new(build_test())
    r2 = Result.new(build_test(), build_test_module())
    assert r1.line == nil
    assert r2.line == nil
  end

  # ---------------------------------------------------------------------------
  # Capture of test-level metadata
  # ---------------------------------------------------------------------------

  test "new/1 captures time_us from test.time" do
    r = Result.new(build_test(time: 12_345))
    assert r.time_us == 12_345
  end

  test "new/1 falls back to 0 when test.time is nil" do
    r = Result.new(build_test(time: nil))
    assert r.time_us == 0
  end

  test "new/1 captures tags verbatim" do
    tags = %{integration: true, slow: "yes"}
    r = Result.new(build_test(tags: tags))
    assert r.tags == tags
  end

  test "new/1 captures module atom from test.module" do
    r = Result.new(build_test(module: :"MyApp.Foo.Test"))
    assert r.module == :"MyApp.Foo.Test"
  end

  test "new/1 captures name atom from test.name" do
    r = Result.new(build_test(name: :"test something specific"))
    assert r.name == :"test something specific"
  end

  test "new/1 preserves the original ExUnit.Test in the :test field" do
    t = build_test()
    r = Result.new(t)
    assert r.test == t
  end

  # ---------------------------------------------------------------------------
  # Boolean predicates
  # ---------------------------------------------------------------------------

  test "passed?/1 returns true only for :passed" do
    assert Result.passed?(result_with(:passed))
    refute Result.passed?(result_with(:failed))
    refute Result.passed?(result_with(:skipped))
    refute Result.passed?(result_with(:excluded))
    refute Result.passed?(result_with(:invalid))
  end

  test "failed?/1 returns true only for :failed" do
    assert Result.failed?(result_with(:failed))
    refute Result.failed?(result_with(:passed))
    refute Result.failed?(result_with(:skipped))
    refute Result.failed?(result_with(:excluded))
  end

  test "skipped?/1 returns true for :skipped and :excluded, false otherwise" do
    assert Result.skipped?(result_with(:skipped))
    assert Result.skipped?(result_with(:excluded))
    refute Result.skipped?(result_with(:passed))
    refute Result.skipped?(result_with(:failed))
    refute Result.skipped?(result_with(:invalid))
  end

  # ---------------------------------------------------------------------------
  # Raw failure preservation — required for downstream rendering and rerun.
  # ---------------------------------------------------------------------------

  test "new/1 preserves raw 3-tuple failure structure" do
    failures = [
      {:error, %RuntimeError{message: "first"}, [{:module, :fun, 0, []}]},
      {:error, %ArgumentError{message: "second"}, [{:module, :fun, 1, []}]}
    ]

    r = Result.new(build_test(state: {:failed, failures}))

    assert length(r.failures) == 2
    [first, second] = r.failures

    assert elem(first, 0) == :error
    assert match?(%RuntimeError{}, elem(first, 1))
    assert is_list(elem(first, 2))

    assert elem(second, 0) == :error
    assert match?(%ArgumentError{}, elem(second, 1))
  end
end
