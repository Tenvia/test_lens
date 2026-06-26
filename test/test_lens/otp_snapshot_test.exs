defmodule TestLens.OTPSnapshotTest do
  use ExUnit.Case, async: true

  alias TestLens.{OTPSnapshot, Result}

  setup do
    # Use the test process as a stand-in pid. It is alive, has no
    # registered name, and is not a GenServer/Agent/Task — so most
    # safety checks return safe_to_capture?/true (no denylist match)
    # but safe_state_hash/1 returns :skip.
    %{pid: self()}
  end

  describe "safe_to_capture?/1" do
    test "returns false for nil" do
      refute OTPSnapshot.safe_to_capture?(nil)
    end

    test "returns false for non-pid input" do
      refute OTPSnapshot.safe_to_capture?("nope")
      refute OTPSnapshot.safe_to_capture?(42)
      refute OTPSnapshot.safe_to_capture?(:atom)
    end

    test "returns true for the live test process" do
      assert OTPSnapshot.safe_to_capture?(self())
    end

    test "returns false for a denylisted registered name" do
      # Spawn a process with a denylisted registered name.
      pid =
        spawn(fn ->
          Process.register(self(), :"MyApp.TokenStore")
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      # Allow the spawn to register.
      Process.sleep(10)
      refute OTPSnapshot.safe_to_capture?(pid)
    end

    test "returns true for a non-denylisted registered name" do
      pid =
        spawn(fn ->
          Process.register(self(), :"MyApp.SafeCache")
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      Process.sleep(10)
      assert OTPSnapshot.safe_to_capture?(pid)
    end

    test "denylist is case-insensitive" do
      pid =
        spawn(fn ->
          Process.register(self(), :"MyApp.PASSWORDHASH")
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      Process.sleep(10)
      refute OTPSnapshot.safe_to_capture?(pid)
    end
  end

  describe "denylisted_registered_name?/1" do
    test "matches token, secret, password, key, credential, auth" do
      for name <- ["Token", "MySecret", "PasswordHash", "APIKey", "Credentials", "OAuth"] do
        assert OTPSnapshot.denylisted_registered_name?(name),
               "expected #{inspect(name)} to match the denylist"
      end
    end

    test "ignores nil and :undefined" do
      refute OTPSnapshot.denylisted_registered_name?(nil)
      refute OTPSnapshot.denylisted_registered_name?(:undefined)
    end

    test "does not match safe names" do
      refute OTPSnapshot.denylisted_registered_name?("MyApp.Repo")
      refute OTPSnapshot.denylisted_registered_name?("Billing.Worker")
      refute OTPSnapshot.denylisted_registered_name?(:"Elixir.MyApp.Foo")
    end
  end

  describe "capture_for_failure/3" do
    test "returns {:error, :not_a_failure} for a passing test" do
      passing = %Result{
        test: nil,
        status: :passed,
        time_us: 0,
        failures: [],
        tags: %{},
        module: SomeMod,
        name: :"test ok",
        file: nil,
        line: nil
      }

      assert {:error, :not_a_failure} =
               OTPSnapshot.capture_for_failure(passing, "ff8e027fa45c", self())
    end

    test "returns a map for a failed test" do
      failing = %Result{
        test: nil,
        status: :failed,
        time_us: 200,
        failures: [{:error, %RuntimeError{message: "boom"}, []}],
        tags: %{},
        module: MyApp.FooTest,
        name: :"test boom",
        file: "test/foo_test.exs",
        line: nil
      }

      snapshot = OTPSnapshot.capture_for_failure(failing, "ff8e027fa45c", self())

      assert is_map(snapshot)
      assert snapshot["snapshot_id"] |> byte_size() == 16
      assert snapshot["test_module"] == inspect(MyApp.FooTest)
      assert snapshot["test_name"] == "test boom"
      assert is_binary(snapshot["captured_at"])
      assert is_list(snapshot["supervision_subtree"])
      assert is_map(snapshot["safety"])
    end

    test "snapshot_id is derived from the failure_id and timestamp" do
      failing = %Result{
        test: nil,
        status: :failed,
        time_us: 200,
        failures: [],
        tags: %{},
        module: MyApp.FooTest,
        name: :"test boom",
        file: nil,
        line: nil
      }

      a = OTPSnapshot.capture_for_failure(failing, "ff8e027fa45c", self())
      b = OTPSnapshot.capture_for_failure(failing, "ff8e027fa45c", self())
      assert is_binary(a["snapshot_id"])
      assert is_binary(b["snapshot_id"])
      # System time advances at least 1 ns between calls.
      assert a["snapshot_id"] != b["snapshot_id"]
    end
  end

  describe "safe_process_info/1" do
    test "returns nil for nil pid" do
      assert OTPSnapshot.safe_process_info(nil) == nil
    end

    test "returns nil for non-pid input" do
      assert OTPSnapshot.safe_process_info("nope") == nil
    end

    test "returns a map for a live, safe pid" do
      info = OTPSnapshot.safe_process_info(self())
      assert is_map(info)
      assert is_integer(info["mailbox_size"])
      assert is_map(info["current_function"])
      assert is_boolean(info["trap_exit"])
    end

    test "does NOT include :messages or :dictionary" do
      info = OTPSnapshot.safe_process_info(self())
      refute Map.has_key?(info, "messages")
      refute Map.has_key?(info, "dictionary")
    end

    test "returns nil for a denylisted registered name" do
      pid =
        spawn(fn ->
          Process.register(self(), :"MyApp.SecretVault")
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      Process.sleep(10)
      assert OTPSnapshot.safe_process_info(pid) == nil
    end
  end

  describe "safe_state_hash/1" do
    test "returns :skip for nil and non-pids" do
      assert OTPSnapshot.safe_state_hash(nil) == :skip
      assert OTPSnapshot.safe_state_hash("nope") == :skip
    end

    test "returns :skip for a non-GenServer pid (the test process)" do
      assert OTPSnapshot.safe_state_hash(self()) == :skip
    end

    test "returns {:ok, hash} for a real GenServer" do
      # Use a tiny dedicated GenServer so :sys.get_state works. Agent
      # alone is fine but we want to assert a GenServer-shaped response.
      defmodule SnapshotHashServer do
        use GenServer

        def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{counter: 0})

        @impl true
        def init(state), do: {:ok, state}
      end

      {:ok, pid} = SnapshotHashServer.start_link()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      case OTPSnapshot.safe_state_hash(pid) do
        {:ok, hash} ->
          assert is_binary(hash)
          assert byte_size(hash) == 32

        :skip ->
          flunk("expected a hash for an Agent-backed process")
      end
    end
  end

  describe "capture_supervision_subtree/2" do
    test "returns empty list when no roots are given" do
      assert OTPSnapshot.capture_supervision_subtree([]) == []
    end

    test "returns empty list when roots exceed max_depth" do
      fake_pid = spawn(fn -> :ok end)
      # depth starting at max_depth is rejected
      assert OTPSnapshot.capture_supervision_subtree([fake_pid], OTPSnapshot.max_depth()) == []
    end
  end

  describe "module-level bounds" do
    test "capture_timeout_ms is 100 by default" do
      assert OTPSnapshot.capture_timeout_ms() == 100
    end

    test "max_depth is 6 by default" do
      assert OTPSnapshot.max_depth() == 6
    end

    test "max_breadth is 64 by default" do
      assert OTPSnapshot.max_breadth() == 64
    end
  end
end
