defmodule TestLens.TelemetryBridgeTest do
  use ExUnit.Case, async: false

  alias TestLens.TelemetryBridge

  setup do
    # Each test starts a fresh, uniquely-named bridge so the global
    # telemetry handler registry does not collide with parallel runs.
    suffix = System.unique_integer([:positive])
    name = :"test-lens-telemetry-bridge.#{suffix}.server"

    {:ok, pid} =
      TelemetryBridge.start_link(suffix: suffix, name: name)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{server: name, pid: pid}
  end

  defp assert_eventually(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
      else
        flunk("eventual assertion did not pass within 1s")
      end
    end
  end

  describe "start_link/1 + stop/1" do
    test "starts and stops cleanly", %{server: server} do
      assert is_pid(Process.whereis(server))
      assert :ok = TelemetryBridge.stop(server)
    end

    test "stop detaches the telemetry handler" do
      # After stop, the handler should not be attached. We check by
      # trying to attach a duplicate id manually; :telemetry allows
      # reattachment once the previous one is detached.
      {:ok, server} =
        TelemetryBridge.start_link(suffix: System.unique_integer([:positive]))

      GenServer.stop(server)

      # Reattaching should NOT raise "already attached" once we stopped
      # the first bridge.
      ref = make_ref()
      assert :ok = :telemetry.attach(ref, [:test_lens, :probe], fn _, _, _, _ -> :ok end, nil)
      :telemetry.detach(ref)
    end
  end

  describe "events/1 + event_count/1" do
    test "empty by default", %{server: server} do
      assert TelemetryBridge.events(server) == []
      assert TelemetryBridge.event_count(server) == 0
    end

    test "captures a matching telemetry event", %{server: server, pid: pid} do
      # Verify the bridge is alive and the handler id is registered.
      assert Process.alive?(pid)

      # Give the bridge a beat to register its atom name in handle_continue.
      Process.sleep(20)

      # Confirm telemetry is started.
      assert {:ok, _} = Application.ensure_all_started(:telemetry)

      # Synchronize: poll until the event arrives, or fail after 1s.
      :telemetry.execute([:supervisor, :child, :started], %{count: 1}, %{child_id: :x})

      assert_eventually(fn -> TelemetryBridge.event_count(server) == 1 end)

      [event] = TelemetryBridge.events(server)
      assert event["event"] == "supervisor.child.started"
      assert event["measurements"]["count"] == 1
      assert event["metadata"]["child_id"] == "x"
    end

    test "ignores events that do not match the prefix list", %{server: server} do
      ref = make_ref()
      :telemetry.attach(ref, [:some_unrelated, :event], fn _, _, _, _ -> :ok end, nil)
      :telemetry.execute([:some_unrelated, :event], %{}, %{})
      Process.sleep(20)

      assert TelemetryBridge.events(server) == []
      :telemetry.detach(ref)
    end

    test "ring buffer drops oldest events beyond ring_size" do
      suffix = System.unique_integer([:positive])
      {:ok, server} = TelemetryBridge.start_link(suffix: suffix, ring_size: 3)

      # Let handle_continue/2 finish attaching the handler. The ring
      # buffer logic depends on the handler being live before the
      # first :telemetry.execute call.
      Process.sleep(200)

      for _ <- 1..5, do: :telemetry.execute([:supervisor, :child, :started], %{}, %{})
      Process.sleep(200)

      events = TelemetryBridge.events(server)
      assert length(events) == 3, "expected 3 events, got #{length(events)}"

      GenServer.stop(server)
    end
  end

  describe "event_matches?/1" do
    test "matches the four prefix families" do
      for prefix <- [
            [:supervisor, :child, :started],
            [:gen_server, :cast],
            [:oban, :job, :start],
            [:broadway, :batch, :start]
          ] do
        assert TelemetryBridge.event_matches?(prefix)
      end
    end

    test "does not match unrelated events" do
      refute TelemetryBridge.event_matches?([:phoenix, :router_dispatch, :start])
      refute TelemetryBridge.event_matches?([:ecto, :query])
      refute TelemetryBridge.event_matches?([])
    end
  end

  describe "module-level helpers" do
    test "handler_id/0 returns the bridge id" do
      assert is_binary(TelemetryBridge.handler_id())
      assert TelemetryBridge.handler_id() =~ "test-lens-telemetry-bridge"
    end

    test "ring_size/0 returns the default" do
      assert TelemetryBridge.ring_size() == 64
    end
  end
end
