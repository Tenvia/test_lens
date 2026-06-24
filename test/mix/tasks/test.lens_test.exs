defmodule Mix.Tasks.Test.LensTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Test.Lens, as: Task

  test "empty args -> {[], [], []}" do
    assert Task.parse([]) == {[], [], []}
  end

  test "-- alone -> {[], [], []}" do
    assert Task.parse(["--"]) == {[], [], []}
  end

  test "-- --failed -> {[], [\"--failed\"], []}" do
    assert Task.parse(["--", "--failed"]) == {[], ["--failed"], []}
  end

  test "--json -- --failed -> {[json: true], [\"--failed\"], []}" do
    assert Task.parse(["--json", "--", "--failed"]) == {[json: true], ["--failed"], []}
  end

  test "--seed 0 after -- -> {[], [\"--seed\", \"0\"], []}" do
    assert Task.parse(["--", "--seed", "0"]) == {[], ["--seed", "0"], []}
  end

  test "-j -- --failed (alias)" do
    assert Task.parse(["-j", "--", "--failed"]) == {[json: true], ["--failed"], []}
  end

  test "--no-color -> {[no_color: true], [], []}" do
    assert Task.parse(["--no-color"]) == {[no_color: true], [], []}
  end

  test "--bogus produces invalid_option error" do
    {_, _, invalid} = Task.parse(["--bogus"])
    assert invalid != []
    assert Enum.any?(invalid, fn
      {:bogus, :invalid_option} -> true
      _ -> false
    end)
  end

  test "test/foo_test.exs:42 after -- passes through unchanged" do
    assert Task.parse(["--", "test/foo_test.exs:42"]) == {[], ["test/foo_test.exs:42"], []}
  end

  test "--json-file PATH is captured" do
    assert Task.parse(["--json-file", "tmp/test_lens/report.json"]) ==
             {[json_file: "tmp/test_lens/report.json"], [], []}
  end

  test "--html is captured" do
    assert Task.parse(["--html"]) == {[html: true], [], []}
  end

  test "--html-file PATH is captured" do
    assert Task.parse(["--html-file", "tmp/test_lens/report.html"]) ==
             {[html_file: "tmp/test_lens/report.html"], [], []}
  end
end