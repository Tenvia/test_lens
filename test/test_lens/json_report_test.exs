defmodule TestLens.JSONReportTest do
  use ExUnit.Case, async: true

  alias TestLens.{JSONReport, Result}

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_json_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp passed_result do
    %Result{
      test: %ExUnit.Test{
        name: :"test ok",
        module: SomeMod,
        state: nil,
        time: 100,
        tags: %{},
        logs: []
      },
      status: :passed,
      time_us: 100,
      failures: [],
      tags: %{},
      module: SomeMod,
      name: :"test ok",
      file: "test/x_test.exs",
      line: nil
    }
  end

  defp failed_result do
    %Result{
      test: %ExUnit.Test{
        name: :"test boom",
        module: SomeMod,
        state: {:failed, []},
        time: 200,
        tags: %{},
        logs: []
      },
      status: :failed,
      time_us: 200,
      failures: [{:error, %RuntimeError{message: "x"}, []}],
      tags: %{},
      module: SomeMod,
      name: :"test boom",
      file: "test/x_test.exs",
      line: nil
    }
  end

  # --- default path --------------------------------------------------------

  test "default_path/0 returns the conventional _build/test_lens path" do
    assert JSONReport.default_path() == "_build/test_lens/report.json"
  end

  # --- build/3 shape -------------------------------------------------------

  test "build/3 includes all required top-level keys" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)

    for key <- [
          "test_lens_version",
          "project",
          "timestamp",
          "seed",
          "totals",
          "times_us",
          "failures",
          "slow",
          "classification_counts",
          "next_commands"
        ] do
      assert Map.has_key?(artifact, key), "missing key: #{key}"
    end
  end

  test "build/3 with no results has zeroed totals" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert artifact["totals"]["tests"] == 0
    assert artifact["totals"]["passed"] == 0
    assert artifact["totals"]["failed"] == 0
  end

  test "build/3 with a passed and a failed result counts correctly" do
    artifact =
      JSONReport.build([passed_result(), failed_result()], %{run: 0, async: nil, load: nil}, nil)

    assert artifact["totals"]["tests"] == 2
    assert artifact["totals"]["passed"] == 1
    assert artifact["totals"]["failed"] == 1
  end

  test "build/3 with an integer seed records it as an integer" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, 12345)
    assert artifact["seed"] == 12345
  end

  test "build/3 with a nil seed records it as null" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert artifact["seed"] == nil
  end

  test "build/3 timestamp is a valid ISO 8601 string" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert is_binary(artifact["timestamp"])
    {:ok, _, _} = DateTime.from_iso8601(artifact["timestamp"])
  end

  test "build/3 failures list contains entries for failed results only" do
    artifact =
      JSONReport.build([passed_result(), failed_result()], %{run: 0, async: nil, load: nil}, nil)

    assert length(artifact["failures"]) == 1
    [failure] = artifact["failures"]
    assert failure["module"] == "SomeMod"
    assert failure["name"] == "test boom"
    assert failure["file"] == "test/x_test.exs"
  end

  test "build/3 failure entry includes classification, impact, and severity" do
    artifact = JSONReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
    [failure] = artifact["failures"]
    assert is_map(failure["classification"])
    assert is_map(failure["impact"])
    assert failure["severity"] in ["critical", "other"]
    assert is_binary(failure["failure_kind"])
  end

  test "build/3 slow list contains top 5 slowest tests" do
    results =
      for i <- 1..10 do
        %Result{passed_result() | time_us: i * 1000, name: :"t#{i}"}
      end

    artifact = JSONReport.build(results, %{run: 0, async: nil, load: nil}, nil)
    assert length(artifact["slow"]) == 5
  end

  test "build/3 next_commands includes --stale always" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)
    stale = Enum.find(artifact["next_commands"], &String.contains?(&1["command"], "--stale"))
    assert stale != nil
  end

  test "build/3 next_commands includes --failed when there are failures" do
    artifact = JSONReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
    failed = Enum.find(artifact["next_commands"], &String.contains?(&1["command"], "--failed"))
    assert failed != nil
  end

  test "build/3 next_commands omits --failed when there are no failures" do
    artifact = JSONReport.build([passed_result()], %{run: 0, async: nil, load: nil}, nil)
    failed = Enum.find(artifact["next_commands"], &String.contains?(&1["command"], "--failed"))
    assert failed == nil
  end

  test "build/3 next_commands includes --seed N when seed is an integer" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, 42)
    seed_cmd = Enum.find(artifact["next_commands"], &String.contains?(&1["command"], "--seed"))
    assert seed_cmd != nil
    assert seed_cmd["command"] =~ "42"
  end

  test "build/3 does not include any environment, secrets, or application config" do
    # The artifact should only have the documented top-level keys.
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)

    expected_keys =
      MapSet.new([
        "test_lens_version",
        "project",
        "timestamp",
        "seed",
        "totals",
        "times_us",
        "failures",
        "slow",
        "classification_counts",
        "next_commands"
      ])

    assert MapSet.new(Map.keys(artifact)) == expected_keys
  end

  test "build/3 classification_counts is a histogram of failure types" do
    artifact =
      JSONReport.build([failed_result(), failed_result()], %{run: 0, async: nil, load: nil}, nil)

    counts = artifact["classification_counts"]
    assert is_map(counts)
    # The exact type may be 'assertion' or 'error' or similar depending on
    # what the classifier picks. Just assert the sum equals the failure count.
    assert Enum.sum(Map.values(counts)) == 2
  end

  # --- write/4 -------------------------------------------------------------

  test "write/4 creates the artifact file at the given path", %{dir: dir} do
    path = Path.join(dir, "report.json")
    assert :ok = JSONReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
    assert File.exists?(path)
  end

  test "write/4 creates parent directories that do not exist", %{dir: dir} do
    path = Path.join([dir, "deep", "nested", "report.json"])
    assert :ok = JSONReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
    assert File.exists?(path)
  end

  test "write/4 the file content is valid JSON", %{dir: dir} do
    path = Path.join(dir, "report.json")

    :ok =
      JSONReport.write(
        path,
        [passed_result(), failed_result()],
        %{run: 0, async: nil, load: nil},
        7
      )

    {:ok, content} = File.read(path)
    # Smoke test: the output should start with '{' and end with '}'.
    # We cannot use Jason.decode/1 here since Jason is not a dependency.
    assert String.starts_with?(content, "{")
    assert String.ends_with?(content, "}")
    assert content =~ "\"test_lens_version\""
    assert content =~ "\"0.1.0\""
    assert content =~ "\"totals\""
  end

  test "write/4 overwrites an existing file", %{dir: dir} do
    path = Path.join(dir, "report.json")
    File.write!(path, "garbage")
    :ok = JSONReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
    {:ok, content} = File.read(path)
    refute content =~ "garbage"
  end

  # --- encode/1 ------------------------------------------------------------

  test "encode/1 returns a valid JSON string" do
    artifact = JSONReport.build([], %{run: 0, async: nil, load: nil}, nil)
    encoded = JSONReport.encode(artifact)
    assert is_binary(encoded)
    # Should be parseable. We use a minimal smoke test: the output
    # should start with '{' and end with '}'.
    assert String.starts_with?(encoded, "{")
    assert String.ends_with?(encoded, "}")
  end
end
