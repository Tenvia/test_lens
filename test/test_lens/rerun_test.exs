defmodule TestLens.RerunTest do
  use ExUnit.Case, async: true

  alias TestLens.{Rerun, Result}

  defp passed_result do
    %Result{
      test: %ExUnit.Test{},
      status: :passed,
      time_us: 100,
      failures: [],
      tags: %{},
      module: SomeMod,
      name: :passes,
      file: "x",
      line: 1
    }
  end

  defp failed_result do
    %Result{
      test: %ExUnit.Test{state: {:failed, []}},
      status: :failed,
      time_us: 200,
      failures: [],
      tags: %{},
      module: SomeMod,
      name: :fails,
      file: "x",
      line: 1
    }
  end

  test "failed_test_args/1 with empty list returns []" do
    assert Rerun.failed_test_args([]) == []
  end

  test "failed_test_args/1 with only passes returns []" do
    assert Rerun.failed_test_args([passed_result()]) == []
  end

  test "failed_test_args/1 with one failed Result returns [\"--failed\"]" do
    assert Rerun.failed_test_args([passed_result(), failed_result()]) == ["--failed"]
  end

  test "rerun_command/1 with failures returns mix test.lens -- --failed" do
    assert Rerun.rerun_command([failed_result()]) == "mix test.lens -- --failed"
  end

  test "rerun_command/1 with empty returns mix test.lens --" do
    assert Rerun.rerun_command([]) == "mix test.lens -- "
  end
end