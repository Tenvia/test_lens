defmodule TestLens.EventStoreTest do
  @moduledoc """
  Tests for `TestLens.EventStore` — the Agent-backed storage the formatter
  writes into. These use a freshly-started store per test (with a unique
  name) so they can run in isolation from the global default store.
  """
  use ExUnit.Case, async: false

  alias TestLens.{EventStore, Result}

  setup do
    # Use a unique server per test so we never collide with the global
    # `TestLens.EventStore` name that the formatter uses during `mix test`.
    name = :"TestLens.EventStoreTest.#{System.unique_integer([:positive])}"
    {:ok, pid} = EventStore.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    %{server: name}
  end

  # ---------------------------------------------------------------------------
  # per-test results
  # ---------------------------------------------------------------------------

  test "put_result/2 then get_results/1 roundtrips a single result", %{server: s} do
    r = %Result{status: :passed, name: :a, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}
    assert :ok = EventStore.put_result(r, s)
    assert [^r] = EventStore.get_results(s)
  end

  test "put_result/2 appends in arrival order", %{server: s} do
    r1 = %Result{status: :passed, name: :first, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}
    r2 = %Result{status: :failed, name: :second, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}
    r3 = %Result{status: :skipped, name: :third, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}

    EventStore.put_result(r1, s)
    EventStore.put_result(r2, s)
    EventStore.put_result(r3, s)

    assert EventStore.get_results(s) == [r1, r2, r3]
  end

  test "reset/1 clears all stored results", %{server: s} do
    r = %Result{status: :passed, name: :a, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}
    EventStore.put_result(r, s)
    assert EventStore.count(s) == 1
    EventStore.reset(s)
    assert EventStore.count(s) == 0
    assert EventStore.get_results(s) == []
  end

  test "count/1 returns the number of stored results", %{server: s} do
    assert EventStore.count(s) == 0

    for i <- 1..3 do
      EventStore.put_result(
        %Result{status: :passed, name: :"t#{i}", module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil},
        s
      )
    end

    assert EventStore.count(s) == 3
  end

  test "count_by_status/2 filters by status", %{server: s} do
    EventStore.put_result(%Result{status: :passed, name: :p1, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}, s)
    EventStore.put_result(%Result{status: :passed, name: :p2, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}, s)
    EventStore.put_result(%Result{status: :failed, name: :f1, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}, s)
    EventStore.put_result(%Result{status: :skipped, name: :s1, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}, s)

    assert EventStore.count_by_status(:passed, s) == 2
    assert EventStore.count_by_status(:failed, s) == 1
    assert EventStore.count_by_status(:skipped, s) == 1
    assert EventStore.count_by_status(:excluded, s) == 0
    assert EventStore.count_by_status(:invalid, s) == 0
  end

  test "put/2 is an alias for put_result/2", %{server: s} do
    r = %Result{status: :passed, name: :a, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}
    EventStore.put(r, s)
    assert EventStore.get_results(s) == [r]
  end

  test "get/1 is an alias for get_results/1", %{server: s} do
    r = %Result{status: :passed, name: :a, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil}
    EventStore.put_result(r, s)
    assert EventStore.get(s) == [r]
  end

  # ---------------------------------------------------------------------------
  # per-module events
  # ---------------------------------------------------------------------------

  test "put_module_event/2 then get_module_events/1 roundtrips", %{server: s} do
    e1 = %{event: :started, name: M1, file: "test/m1_test.exs"}
    e2 = %{event: :finished, name: M1, file: "test/m1_test.exs", state: nil}

    EventStore.put_module_event(e1, s)
    EventStore.put_module_event(e2, s)

    assert EventStore.get_module_events(s) == [e1, e2]
  end

  test "module_names/1 returns unique module names in insertion order" do
    # Uses a separate, freshly-started store so we can re-test without
    # racing against the setup-started one.
    name = :"TestLens.EventStoreTest.uniq.#{System.unique_integer([:positive])}"
    {:ok, pid} = EventStore.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

    EventStore.put_module_event(%{event: :started, name: M1, file: "x"}, name)
    EventStore.put_module_event(%{event: :started, name: M2, file: "y"}, name)
    EventStore.put_module_event(%{event: :finished, name: M1, file: "x"}, name)

    assert EventStore.module_names(name) == [M1, M2]
  end

  test "latest_module_event/2 returns the most recent event for a name", %{server: s} do
    e1 = %{event: :started, name: M1, file: "x"}
    e2 = %{event: :finished, name: M1, file: "x", state: {:failed, []}}

    EventStore.put_module_event(e1, s)
    EventStore.put_module_event(e2, s)

    assert EventStore.latest_module_event(M1, s) == e2
  end

  test "latest_module_event/2 returns nil for an unseen module", %{server: s} do
    assert EventStore.latest_module_event(:NoSuchMod, s) == nil
  end

  test "reset/1 also clears module events", %{server: s} do
    EventStore.put_module_event(%{event: :started, name: M1, file: "x"}, s)
    EventStore.put_result(
      %Result{status: :passed, name: :a, module: M1, file: nil, line: nil, tags: %{}, time_us: 0, failures: [], test: nil},
      s
    )

    assert EventStore.get_module_events(s) != []
    EventStore.reset(s)
    assert EventStore.get_module_events(s) == []
    assert EventStore.get_results(s) == []
  end
end
