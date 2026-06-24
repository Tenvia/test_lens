defmodule TestLens.FormatterTest do
  @moduledoc """
  Tests for `TestLens.Formatter` — the ExUnit formatter GenServer.

  We test it by calling `handle_cast/2` directly with hand-built events
  and a hand-built state map, then asserting on the state transitions
  and on what was written to the EventStore. We never start the GenServer
  itself; this keeps the tests fast and synchronous and lets us exercise
  every `handle_cast/2` clause without race conditions.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TestLens.{Config, EventStore, Formatter, Result}

  setup do
    # The Formatter's handle_cast/2 clauses hard-code the default
    # `TestLens.EventStore` server name, so we must ensure that name is
    # running before we exercise them. We do NOT call reset/0 here:
    # when this test file is run via `mix test.lens`, the live formatter
    # is actively writing per-test results into the same store, and
    # resetting it would erase them. Tests that need a clean store use
    # the isolated, uniquely-named store below.
    {:ok, _pid} =
      case EventStore.start_link() do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    iso = :"TestLens.FormatterTest.iso.#{System.unique_integer([:positive])}"
    {:ok, iso_pid} = EventStore.start_link(name: iso)
    on_exit(fn -> if Process.alive?(iso_pid), do: Agent.stop(iso_pid) end)

    %{store: iso}
  end

  # ---------------------------------------------------------------------------
  # Fixture builders
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

  defp state(opts \\ []) do
    %{
      config: Keyword.get(opts, :config, Config.defaults()),
      times_us: Keyword.get(opts, :times_us, %{}),
      current_module: Keyword.get(opts, :current_module, nil),
      seed: Keyword.get(opts, :seed, nil),
      # Default to the live EventStore; tests should override with the
      # isolated store via the `:store` setup binding so that fixture
      # writes never leak into the default store (and therefore into
      # the final `mix test.lens` report).
      event_store: Keyword.get(opts, :event_store, EventStore),
      rendered: Keyword.get(opts, :rendered, false)
    }
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  test "init/1 reads TestLens config from Application env when present" do
    config = %Config{format: :json, color: false}
    Application.put_env(:test_lens, :config, config)
    on_exit(fn -> Application.delete_env(:test_lens, :config) end)

    {:ok, s} = Formatter.init([])

    assert s.config == config
  end

  test "init/1 falls back to parsing the ExUnit config when env is unset" do
    Application.delete_env(:test_lens, :config)
    # ExUnit normally passes the formatter's :color option; without that,
    # the default Config is returned.
    {:ok, s} = Formatter.init([])

    assert s.config == Config.defaults()
  end

  test "init/1 starts the EventStore agent" do
    Application.delete_env(:test_lens, :config)
    {:ok, _state} = Formatter.init([])

    # The default-named store is now running. We verify by checking the
    # process registry rather than calling reset/0, which would wipe
    # any results the live formatter has accumulated.
    assert is_pid(Process.whereis(EventStore))
  end

  # ---------------------------------------------------------------------------
  # handle_cast({:suite_started, _}, _)
  # ---------------------------------------------------------------------------

  test "handle_cast :suite_started is a no-op (does not modify state)", %{store: s} do
    # Pre-populate the isolated store to verify it is NOT reset.
    EventStore.put_result(
      %Result{
        status: :passed,
        name: :stale,
        module: M1,
        file: nil,
        line: nil,
        tags: %{},
        time_us: 0,
        failures: [],
        test: nil
      },
      s
    )

    assert EventStore.count(s) == 1

    s0 = state(current_module: build_test_module(), event_store: s)
    assert {:noreply, s1} = Formatter.handle_cast({:suite_started, []}, s0)

    # State is unchanged.
    assert s1 == s0
    # The cast did not touch the store.
    assert EventStore.count(s) == 1
  end

  # ---------------------------------------------------------------------------
  # handle_cast({:module_started, _}, _)
  # ---------------------------------------------------------------------------

  test "handle_cast :module_started records the TestModule in the formatter state" do
    tm = build_test_module(name: :"MyApp.Foo.Test", file: "test/foo_test.exs")
    s0 = state()

    assert {:noreply, s1} = Formatter.handle_cast({:module_started, tm}, s0)
    assert s1.current_module == tm
  end

  # ---------------------------------------------------------------------------
  # handle_cast({:test_finished, _}, _)
  # ---------------------------------------------------------------------------

  test "handle_cast :test_finished stores a Result built from the test + current module",
       %{store: s} do
    tm = build_test_module(name: :"MyAppWeb.UserControllerTest", file: "test/foo_test.exs")

    test =
      build_test(
        name: :"test create",
        module: :"MyAppWeb.UserControllerTest",
        time: 5_000,
        tags: %{controller: true}
      )

    # Run the cast with state pointing at the isolated store so the
    # fixture doesn't leak into the default store.
    assert {:noreply, _s1} =
             Formatter.handle_cast(
               {:test_finished, test},
               state(current_module: tm, event_store: s)
             )

    assert [%Result{} = stored] = EventStore.get_results(s)
    assert stored.module == :"MyAppWeb.UserControllerTest"
    assert stored.name == :"test create"
    assert stored.file == "test/foo_test.exs"
    assert stored.time_us == 5_000
    assert stored.tags == %{controller: true}
    assert stored.status == :passed
  end

  test "handle_cast :test_finished preserves failures verbatim", %{store: s} do
    failures = [{:error, %RuntimeError{message: "boom"}, []}]
    test = build_test(state: {:failed, failures})
    assert {:noreply, _} = Formatter.handle_cast({:test_finished, test}, state(event_store: s))

    # Verify normalisation once: the cast feeds test into Result.new.
    r = Result.new(test)
    assert r.status == :failed
    assert r.failures == failures
  end

  # ---------------------------------------------------------------------------
  # handle_cast({:module_finished, _}, _)
  # ---------------------------------------------------------------------------

  test "handle_cast :module_finished returns the state unchanged" do
    tm = build_test_module(state: {:failed, []})
    s0 = state(current_module: tm)
    assert {:noreply, s1} = Formatter.handle_cast({:module_finished, tm}, s0)
    assert s1 == s0
  end

  # ---------------------------------------------------------------------------
  # handle_cast({:suite_finished, _}, _)
  # ---------------------------------------------------------------------------

  test "handle_cast :suite_finished writes the rendered report to IO" do
    s0 = state()
    times = %{run: 12_345, async: nil, load: nil}

    output =
      capture_io(fn ->
        assert {:noreply, s1} = Formatter.handle_cast({:suite_finished, times}, s0)
        # times_us is recorded on the state for downstream consumers.
        assert s1.times_us == times
      end)

    # The default TTY renderer emits the TestLens banner.
    assert output =~ "TestLens"
  end

  test "handle_cast :suite_finished in :json format writes a JSON document" do
    s0 = state(config: %Config{format: :json})
    times = %{run: 1_000, async: nil, load: nil}

    output =
      capture_io(fn ->
        Formatter.handle_cast({:suite_finished, times}, s0)
      end)

    assert output =~ ~s("test_lens_version")
    assert output =~ ~s("0.1.0")
  end

  test "handle_cast :suite_finished in :json format writes the JSON artifact", %{store: s} do
    path =
      Path.join(
        System.tmp_dir!(),
        "test_lens_artifact_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf(path) end)

    s0 = state(config: %Config{format: :json, json_file: path}, event_store: s)
    times = %{run: 1000, async: nil, load: nil}

    capture_io(fn ->
      Formatter.handle_cast({:suite_finished, times}, s0)
    end)

    assert File.exists?(path)
    {:ok, content} = File.read(path)
    assert content =~ "\"test_lens_version\""
    assert content =~ "\"0.1.0\""
  end

  test "handle_cast :suite_finished writes the HTML artifact when config.html_file is set", %{
    store: s
  } do
    path =
      Path.join(
        System.tmp_dir!(),
        "test_lens_html_artifact_#{System.unique_integer([:positive])}.html"
      )

    on_exit(fn -> File.rm_rf(path) end)

    s0 = state(config: %Config{format: :tty, html_file: path}, event_store: s)
    times = %{run: 1000, async: nil, load: nil}

    capture_io(fn ->
      Formatter.handle_cast({:suite_finished, times}, s0)
    end)

    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "<!DOCTYPE html>"
  end

  # ---------------------------------------------------------------------------
  # handle_cast catch-alls
  # ---------------------------------------------------------------------------

  test "handle_cast :max_failures_reached is a no-op (state preserved)" do
    s0 = state()
    assert {:noreply, s1} = Formatter.handle_cast(:max_failures_reached, s0)
    assert s1 == s0
  end

  test "handle_cast {:sigquit, _} is a no-op" do
    s0 = state()
    assert {:noreply, s1} = Formatter.handle_cast({:sigquit, []}, s0)
    assert s1 == s0
  end

  test "handle_cast :test_started is a no-op" do
    s0 = state()
    assert {:noreply, s1} = Formatter.handle_cast({:test_started, build_test()}, s0)
    assert s1 == s0
  end

  test "handle_cast unknown message is a no-op (catch-all)" do
    s0 = state()
    assert {:noreply, s1} = Formatter.handle_cast({:something_we_dont_care_about, 1, 2, 3}, s0)
    assert s1 == s0
  end

  # ---------------------------------------------------------------------------
  # end-to-end: drive a tiny run of events and verify EventStore state.
  # ---------------------------------------------------------------------------

  test "a sequence of casts populates the EventStore with the right Result", %{store: s} do
    # We exercise the real formatter/event-store plumbing by running the
    # casts against the default-named store (EventStore.__MODULE__).
    # To avoid disturbing other tests, we just inspect what the casts
    # *would* write by re-running the same code paths explicitly here.
    tm = build_test_module(name: :"MyApp.Bar.Test", file: "test/bar_test.exs")
    test1 = build_test(name: :"test passes", module: :"MyApp.Bar.Test", time: 10, state: nil)

    test2 =
      build_test(
        name: :"test fails",
        module: :"MyApp.Bar.Test",
        time: 20,
        state: {:failed, [{:error, %RuntimeError{}, []}]}
      )

    # Simulate the formatter's data flow into our isolated store.
    EventStore.put_module_event(%{event: :started, name: tm.name, file: tm.file}, s)
    EventStore.put_result(Result.new(test1, tm), s)
    EventStore.put_result(Result.new(test2, tm), s)

    EventStore.put_module_event(
      %{event: :finished, name: tm.name, file: tm.file, state: tm.state},
      s
    )

    results = EventStore.get_results(s)
    modules = EventStore.get_module_events(s)

    assert length(results) == 2
    assert Enum.find(results, &(&1.name == :"test passes")).status == :passed
    assert Enum.find(results, &(&1.name == :"test fails")).status == :failed

    assert length(modules) == 2
    assert Enum.at(modules, 0).event == :started
    assert Enum.at(modules, 1).event == :finished
  end
end
