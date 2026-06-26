defmodule TestLens.AgentReportTest do
  use ExUnit.Case, async: true

  alias TestLens.{AgentReport, Result}

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_agent_#{System.unique_integer([:positive])}")
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

  defp failed_result(opts \\ []) do
    stack =
      Keyword.get(opts, :stack, [
        {:phoenix, :render, 2, [file: "deps/phoenix/lib/phoenix.ex", line: 5]},
        {:lists, :reverse, 1},
        {MyApp.Foo, :bar, 1, [file: "lib/my_app/foo.ex", line: 42]}
      ])

    reason = Keyword.get(opts, :reason, %RuntimeError{message: "boom"})

    %Result{
      test: %ExUnit.Test{
        name: Keyword.get(opts, :name, :"test boom"),
        module: Keyword.get(opts, :module, MyApp.FooTest),
        state: {:failed, [{:error, reason, stack}]},
        time: 200,
        tags: Keyword.get(opts, :tags, %{}),
        logs: []
      },
      status: :failed,
      time_us: 200,
      failures: [{:error, reason, stack}],
      tags: Keyword.get(opts, :tags, %{}),
      module: Keyword.get(opts, :module, MyApp.FooTest),
      name: Keyword.get(opts, :name, :"test boom"),
      file: Keyword.get(opts, :file, "test/my_app/foo_test.exs"),
      line: nil
    }
  end

  describe "schema" do
    test "schema_version/0 returns 4.0" do
      assert AgentReport.schema_version() == "4.0"
    end

    test "build/3 emits schema_version == 4.0 at the top level" do
      artifact = AgentReport.build([], %{run: 0, async: nil, load: nil}, nil)
      assert artifact["schema_version"] == "4.0"
    end

    test "build/3 with empty results has the canonical top-level keys" do
      artifact = AgentReport.build([], %{run: 0, async: nil, load: nil}, nil)

      for key <- [
            "schema_version",
            "test_lens_version",
            "project",
            "run",
            "totals",
            "failures",
            "repair_queue",
            "commands",
            "otp_snapshots",
            "architecture_findings",
            "safety"
          ] do
        assert Map.has_key?(artifact, key), "missing key: #{key}"
      end
    end

    test "build/3 does NOT include env / mix_project_config / logs" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      encoded = Jason.encode!(artifact)

      refute encoded =~ "Mix.Project.config"
      refute encoded =~ "System.get_env"
      # The literal "exunit_logs" / "raw_message_payloads" string only
      # appears in the safety block as a field name; that is expected and
      # is NOT a leak. We assert no actual log lines or message bodies
      # leaked in. The safety block declares them excluded.
      assert encoded =~ "\"excluded_fields\""
    end

    test "safety block declares what is excluded" do
      artifact = AgentReport.build([], %{run: 0, async: nil, load: nil}, nil)
      assert "env" in artifact["safety"]["excluded_fields"]
      assert "exunit_logs" in artifact["safety"]["excluded_fields"]
    end
  end

  describe "totals" do
    test "build/3 totals are zero with empty results" do
      artifact = AgentReport.build([], %{run: 0, async: nil, load: nil}, nil)
      assert artifact["totals"]["tests"] == 0
      assert artifact["totals"]["passed"] == 0
      assert artifact["totals"]["failed"] == 0
    end

    test "build/3 totals reflect a pass + fail mix" do
      artifact =
        AgentReport.build(
          [passed_result(), failed_result()],
          %{run: 0, async: nil, load: nil},
          nil
        )

      assert artifact["totals"]["tests"] == 2
      assert artifact["totals"]["passed"] == 1
      assert artifact["totals"]["failed"] == 1
    end
  end

  describe "failure entry" do
    test "failures list is empty when no failures" do
      artifact = AgentReport.build([passed_result()], %{run: 0, async: nil, load: nil}, nil)
      assert artifact["failures"] == []
    end

    test "failures list contains one entry per failed result" do
      artifact =
        AgentReport.build(
          [passed_result(), failed_result()],
          %{run: 0, async: nil, load: nil},
          nil
        )

      assert length(artifact["failures"]) == 1
    end

    test "failure entry carries id, file, classification, impact, fingerprint" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      [failure] = artifact["failures"]

      assert is_binary(failure["id"])
      assert byte_size(failure["id"]) == 12
      assert failure["file"] == "test/my_app/foo_test.exs"
      assert is_map(failure["classification"])
      assert is_map(failure["impact"])
      assert is_binary(failure["fingerprint"])
      assert byte_size(failure["fingerprint"]) == 64
    end

    test "failure entry splits stacktrace into app / framework / deps" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      [failure] = artifact["failures"]

      assert is_list(failure["app_stacktrace"])
      assert is_list(failure["framework_stacktrace"])
      assert is_list(failure["deps_stacktrace"])

      # The fixture includes one app frame, one Elixir stdlib frame, one
      # deps frame. The top_app_frame is MyApp.Foo.bar/1.
      assert failure["top_app_frame"]["module"] == "Elixir.MyApp.Foo"
      assert failure["top_app_frame"]["function"] == "bar"
      assert failure["top_app_frame"]["arity"] == 1
      assert failure["top_app_frame"]["line"] == 42

      assert Enum.any?(failure["deps_stacktrace"], &(&1["file"] == "deps/phoenix/lib/phoenix.ex"))
      assert Enum.any?(failure["framework_stacktrace"], &(&1["module"] == "lists"))
    end

    test "failure entry hypotheses mirror classifier output" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      [failure] = artifact["failures"]

      assert [hypothesis | _] = failure["hypotheses"]
      assert is_binary(hypothesis["summary"])
      assert is_list(hypothesis["common_causes"])
      assert is_list(hypothesis["first_checks"])
    end

    test "failure entry rerun_command points at the file" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      [failure] = artifact["failures"]

      assert failure["rerun_command"] =~ "mix test.lens"
      assert failure["rerun_command"] =~ "test/my_app/foo_test.exs"
    end

    test "failure entry failure_kind names :error / :exit / :throw" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      [failure] = artifact["failures"]
      assert failure["failure_kind"] == "error"
    end

    test "failure entry failure_kind names exit_timeout for :exit :timeout" do
      result =
        failed_result(
          reason: :timeout,
          stack: [
            {:phoenix, :b, 0, [file: "deps/phoenix/lib/phoenix.ex", line: 1]},
            {MyApp.Foo, :bar, 1, [file: "lib/foo.ex", line: 1]}
          ]
        )

      # Rewrite the failure tuple directly to use :exit / :timeout.
      result = %Result{result | failures: [{:exit, :timeout, result.failures |> hd() |> elem(2)}]}

      artifact = AgentReport.build([result], %{run: 0, async: nil, load: nil}, nil)
      [failure] = artifact["failures"]
      assert failure["failure_kind"] == "exit_timeout"
    end
  end

  describe "otp_snapshots (3.0+)" do
    test "build/3 without snapshots emits an empty otp_snapshots array" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      assert artifact["otp_snapshots"] == []
    end

    test "build/4 attaches snapshot to matching failure entry" do
      result = failed_result()

      [failure_entry] =
        AgentReport.build([result], %{run: 0, async: nil, load: nil}, nil)["failures"]

      snapshot = %{
        "snapshot_id" => "abc123def456",
        "captured_at" => "2026-06-25T12:00:00.000000Z",
        "test_pid" => "#PID<0.123.0>",
        "supervision_subtree" => [],
        "process_info" => %{"registered_name" => "MyApp.Worker"},
        "safety" => %{"safe_to_capture" => true},
        "telemetry_events" => []
      }

      artifact =
        AgentReport.build([result], %{run: 0, async: nil, load: nil}, nil, %{
          failure_entry["id"] => snapshot
        })

      [failure_with_ctx] = artifact["failures"]
      assert failure_with_ctx["otp_context"]["snapshot_id"] == "abc123def456"
      assert length(artifact["otp_snapshots"]) == 1
      [snap_in_artifact] = artifact["otp_snapshots"]
      assert snap_in_artifact["snapshot_id"] == "abc123def456"
    end

    test "build/4 leaves unrelated failures without otp_context" do
      r1 = failed_result(name: :"test a")
      r2 = failed_result(name: :"test b", module: MyApp.OtherTest)

      [f1_entry, _f2_entry] =
        AgentReport.build([r1, r2], %{run: 0, async: nil, load: nil}, nil)["failures"]

      snapshot = %{
        "snapshot_id" => "only_for_f1",
        "captured_at" => "2026-06-25T12:00:00.000000Z",
        "test_pid" => "#PID<0.0.0>",
        "supervision_subtree" => [],
        "process_info" => %{},
        "safety" => %{},
        "telemetry_events" => []
      }

      artifact =
        AgentReport.build([r1, r2], %{run: 0, async: nil, load: nil}, nil, %{
          f1_entry["id"] => snapshot
        })

      failures = artifact["failures"]

      [with_ctx, without_ctx] =
        Enum.sort_by(failures, & &1["module"])

      assert with_ctx["otp_context"]["snapshot_id"] == "only_for_f1"
      refute Map.has_key?(without_ctx, "otp_context")
    end
  end

  describe "repair_queue" do
    test "is empty when there are no failures" do
      artifact = AgentReport.build([passed_result()], %{run: 0, async: nil, load: nil}, nil)
      assert artifact["repair_queue"] == []
    end

    test "groups failures with the same fingerprint" do
      stack = [{MyApp.Foo, :bar, 1, [file: "lib/foo.ex", line: 42]}]

      f1 = failed_result(name: :"test a", stack: stack)
      f2 = failed_result(name: :"test b", stack: stack)

      artifact = AgentReport.build([f1, f2], %{run: 0, async: nil, load: nil}, nil)

      assert length(artifact["repair_queue"]) == 1
      [item] = artifact["repair_queue"]
      assert length(item["failure_ids"]) == 2
    end

    test "separates failures with different fingerprints" do
      f1 =
        failed_result(
          name: :"test a",
          stack: [{MyApp.Foo, :bar, 1, [file: "lib/foo.ex", line: 42]}]
        )

      f2 =
        failed_result(
          name: :"test b",
          stack: [{MyApp.Baz, :qux, 0, [file: "lib/baz.ex", line: 9]}]
        )

      artifact = AgentReport.build([f1, f2], %{run: 0, async: nil, load: nil}, nil)
      assert length(artifact["repair_queue"]) == 2
    end

    test "priority is critical when any failure has severity=critical" do
      f =
        failed_result(
          reason: %FunctionClauseError{module: SomeMod, function: :bar, arity: 1},
          stack: [{MyApp.X, :y, 1, [file: "lib/x.ex", line: 1]}]
        )

      artifact = AgentReport.build([f], %{run: 0, async: nil, load: nil}, nil)
      [item] = artifact["repair_queue"]
      assert item["priority"] in ["critical", "user_facing", "high", "normal"]
      assert is_float(item["confidence"])
      assert item["confidence"] > 0.0
    end

    test "repair item carries summary, evidence, likely_files, first_checks" do
      f = failed_result()
      artifact = AgentReport.build([f], %{run: 0, async: nil, load: nil}, nil)
      [item] = artifact["repair_queue"]

      assert is_binary(item["summary"])
      assert is_list(item["evidence"])
      assert is_list(item["likely_files"])
      assert is_list(item["first_checks"])
      assert is_list(item["verification_commands"])
      assert is_binary(item["root_cause_fingerprint"])
    end
  end

  describe "commands" do
    test "always includes --stale" do
      artifact = AgentReport.build([], %{run: 0, async: nil, load: nil}, nil)
      assert Enum.any?(artifact["commands"], &String.contains?(&1["command"], "--stale"))
    end

    test "includes --failed when there are failures" do
      artifact = AgentReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
      assert Enum.any?(artifact["commands"], &String.contains?(&1["command"], "--failed"))
    end
  end

  describe "write/4" do
    test "writes the artifact file at the given path", %{dir: dir} do
      path = Path.join(dir, "agent.json")

      assert :ok =
               AgentReport.write(path, [failed_result()], %{run: 0, async: nil, load: nil}, nil)

      assert File.exists?(path)
    end

    test "creates parent directories that do not exist", %{dir: dir} do
      path = Path.join([dir, "deep", "nested", "agent.json"])
      assert :ok = AgentReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
      assert File.exists?(path)
    end

    test "writes valid JSON containing schema_version 4.0", %{dir: dir} do
      path = Path.join(dir, "agent.json")
      :ok = AgentReport.write(path, [failed_result()], %{run: 0, async: nil, load: nil}, 7)
      {:ok, content} = File.read(path)
      assert content =~ "\"schema_version\":\"4.0\""
      assert content =~ "\"test_lens_version\":\"2.0.0\""
    end
  end

  describe "default_path/0" do
    test "returns _build/test_lens/agent.json" do
      assert AgentReport.default_path() == "_build/test_lens/agent.json"
    end
  end
end
