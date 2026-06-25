defmodule TestLens.Formatter do
  @moduledoc """
  ExUnit formatter that buffers per-test results via `TestLens.EventStore`
  and emits a TestLens header / summary at suite boundaries.

  The EventStore server reference is read from `Application.get_env(:test_lens,
  :event_store, TestLens.EventStore)` at startup and stored in the GenServer
  state. Tests can override this to direct the formatter at an isolated
  store and avoid polluting the default store when the formatter test file
  is itself part of the suite being run.

  ## Lifecycle

  ExUnit may start multiple formatter processes within a single run
  (one per phase in some configurations, or for other internal reasons).
  The `EventStore` is a named Agent shared across all formatter instances,
  so writes accumulate across them. We render on the first
  `{:suite_finished, times_us}` call that carries a `:run` key, which
  ExUnit only sets on the final phase. We do NOT reset the store in this
  formatter — the consumer is responsible for starting with a clean store
  (typically by exiting the VM between runs).
  """
  use GenServer

  alias TestLens.{Config, EventStore, HTMLReport, JSONReport, Result, TerminalReporter}

  # ExUnit passes the ExUnit config keyword list to init/1.
  @impl GenServer
  def init(opts) do
    # The Mix task publishes the TestLens config to the application environment
    # because ExUnit's --formatter flag does not forward key:value options to
    # the formatter. If the env is unset (e.g. formatter started outside the
    # task), we fall back to parsing the ExUnit opts as a TestLens config.
    config =
      case Application.get_env(:test_lens, :config) do
        %Config{} = c -> c
        _ -> Config.from_option_parser(opts)
      end

    # The ProjectConfig (consumer's .test_lens.exs) is published to the
    # application environment by the Mix task at the consumer's project
    # root. We do NOT reload it here: the formatter's cwd (the test
    # process cwd, e.g. apps/<app>/ in an umbrella) is not the cwd where
    # .test_lens.exs lives. Impact.classify/1 falls back to loading
    # from cwd if the app env is unset, so the contract still holds for
    # callers that start the formatter outside the mix task.

    seed = Keyword.get(opts, :seed)

    # Resolve the EventStore server once, at startup. Default is the
    # default-named `TestLens.EventStore`; tests can override via env.
    event_store = Application.get_env(:test_lens, :event_store, EventStore)

    # Ensure the default-named EventStore agent is running; safe to call
    # repeatedly because Agent.start_link returns {:error,
    # {:already_started, _}} on duplicates. We do this only for the default
    # store — if a test overrode :event_store, that store must already be
    # started (typically by the test's own setup).
    if event_store == EventStore do
      case EventStore.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    {:ok,
     %{
       config: config,
       times_us: %{},
       current_module: nil,
       seed: seed,
       event_store: event_store,
       # ExUnit may fire :suite_finished multiple times. We render only
       # once, on the call that carries the :run key (which ExUnit only
       # sets on the final phase).
       rendered: false
     }}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def handle_cast({:suite_started, _opts}, state) do
    # No-op: we don't reset the store here. ExUnit may start the formatter
    # more than once within a single VM, and resetting would erase data
    # the live formatter has already accumulated. The consumer is
    # responsible for starting with a clean store between runs.
    {:noreply, state}
  end

  def handle_cast({:test_started, _test}, state) do
    {:noreply, state}
  end

  def handle_cast({:test_finished, test}, state) do
    result = Result.new(test, state.current_module)
    EventStore.put_result(result, state.event_store)
    {:noreply, state}
  end

  def handle_cast({:module_started, test_module}, state) do
    # ExUnit.TestModule struct carries the :file field for the current test file.
    # We track the most recent one so Result.new/2 can populate Result.file,
    # and we also record the module-start event in the EventStore.
    EventStore.put_module_event(
      %{
        event: :started,
        name: test_module.name,
        file: test_module.file
      },
      state.event_store
    )

    {:noreply, %{state | current_module: test_module}}
  end

  def handle_cast({:module_finished, test_module}, state) do
    # Capture the module's final state. ExUnit.TestModule.state is
    # nil when every test in the module passed, or {:failed, failures}
    # when at least one test failed. We preserve the raw state for any
    # downstream reporter that wants to surface module-level rollups.
    EventStore.put_module_event(
      %{
        event: :finished,
        name: test_module.name,
        file: test_module.file,
        state: test_module.state
      },
      state.event_store
    )

    {:noreply, state}
  end

  def handle_cast({:suite_finished, times_us}, state) do
    # ExUnit may fire :suite_finished for each phase. The final phase
    # always carries the :run key; earlier phases (load, async) do not.
    # We render only once, on the first call that includes :run.
    if state.rendered or not Map.has_key?(times_us, :run) do
      {:noreply, %{state | times_us: times_us}}
    else
      results = EventStore.get_results(state.event_store)
      IO.write(TerminalReporter.render(state.config, results, times_us, state.seed))

      # When JSON is enabled (or json_file is set), write the structured JSON artifact.
      if state.config.format == :json or state.config.json_file do
        path = state.config.json_file || JSONReport.default_path()
        _ = JSONReport.write(path, results, times_us, state.seed)
      end

      if state.config.html_file || state.config.format == :html do
        path = state.config.html_file || HTMLReport.default_path()
        _ = HTMLReport.write(path, results, times_us, state.seed)
      end

      {:noreply, %{state | times_us: times_us, rendered: true}}
    end
  end

  def handle_cast(:max_failures_reached, state), do: {:noreply, state}
  def handle_cast({:sigquit, _items}, state), do: {:noreply, state}
  def handle_cast(_msg, state), do: {:noreply, state}
end
