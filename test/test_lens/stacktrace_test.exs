defmodule TestLens.StacktraceTest do
  use ExUnit.Case, async: true

  alias TestLens.Stacktrace

  describe "split/1" do
    test "returns three empty buckets for nil" do
      assert Stacktrace.split(nil) == %{"app" => [], "framework" => [], "deps" => []}
    end

    test "returns three empty buckets for []" do
      assert Stacktrace.split([]) == %{"app" => [], "framework" => [], "deps" => []}
    end

    test "classifies app frames (file under app paths)" do
      frame = {MyApp.Foo, :bar, 1, [file: "lib/my_app/foo.ex", line: 42]}
      result = Stacktrace.split([frame])
      assert length(result["app"]) == 1
      assert result["framework"] == []
      assert result["deps"] == []
    end

    test "classifies deps frames (file under deps/)" do
      frame = {SomeDep, :bar, 1, [file: "deps/some_dep/lib/some_dep.ex", line: 10]}
      result = Stacktrace.split([frame])
      assert result["app"] == []
      assert result["deps"] != []
      assert result["framework"] == []
    end

    test "classifies framework frames (file under _build/)" do
      frame = {SomeDep, :bar, 1, [file: "_build/dev/lib/some_dep/ebin/some_dep.ex", line: 1]}
      result = Stacktrace.split([frame])
      assert result["framework"] != []
    end

    test "classifies framework frames (Elixir module names without file)" do
      frame = {:lists, :reverse, 1}
      result = Stacktrace.split([frame])
      assert result["framework"] != []
      assert result["app"] == []
    end

    test "falls back to :app when module/file cannot be classified" do
      frame = {SomeUnknown, :bar, 1}
      result = Stacktrace.split([frame])
      assert result["app"] != []
    end

    test "preserves frame order within a bucket (reverse order, head first)" do
      f1 = {MyApp.A, :a, 0, [file: "lib/a.ex", line: 1]}
      f2 = {MyApp.B, :b, 0, [file: "lib/b.ex", line: 2]}
      result = Stacktrace.split([f1, f2])

      assert [first, second] = result["app"]
      assert first["function"] == "a"
      assert second["function"] == "b"
    end
  end

  describe "top_app_frame/1" do
    test "returns nil for empty stacktrace" do
      assert Stacktrace.top_app_frame(nil) == nil
      assert Stacktrace.top_app_frame([]) == nil
    end

    test "returns the first app frame" do
      app_frame = {MyApp.Foo, :bar, 1, [file: "lib/foo.ex", line: 10]}
      frame = Stacktrace.top_app_frame([app_frame])
      assert frame["module"] == "Elixir.MyApp.Foo"
      assert frame["function"] == "bar"
      assert frame["arity"] == 1
      assert frame["file"] == "lib/foo.ex"
      assert frame["line"] == 10
    end

    test "skips framework and deps frames to find the top app frame" do
      dep_frame = {SomeDep, :b, 0, [file: "deps/d/lib/d.ex", line: 1]}
      stdlib_frame = {:lists, :reverse, 1}
      app_frame = {MyApp.Foo, :bar, 1, [file: "lib/foo.ex", line: 10]}

      frame = Stacktrace.top_app_frame([dep_frame, stdlib_frame, app_frame])
      assert frame["module"] == "Elixir.MyApp.Foo"
    end

    test "returns nil when no app frames are present" do
      dep_frame = {SomeDep, :b, 0, [file: "deps/d/lib/d.ex", line: 1]}
      assert Stacktrace.top_app_frame([dep_frame]) == nil
    end
  end
end
