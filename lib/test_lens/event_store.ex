defmodule TestLens.EventStore do
  @moduledoc """
  Agent-based store for normalized ExUnit events emitted by
  `TestLens.Formatter`.

  The store is a small process-local scratchpad. It holds per-test
  `TestLens.Result` records and per-module `{name, file, state}` summaries
  so that the terminal reporter can render a useful end-of-run report
  without re-parsing ExUnit's events.
  """

  @doc """
  Starts the EventStore agent.
  Accepts an optional name via keyword list; defaults to __MODULE__.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> empty_state() end, name: name)
  end

  @doc "Returns a child spec for the EventStore."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # --- per-test results ----------------------------------------------------

  @doc "Stores a test result, appending to the end of the list."
  @spec put_result(TestLens.Result.t(), GenServer.server()) :: :ok
  def put_result(result, server \\ __MODULE__) do
    Agent.update(server, fn state ->
      %{state | results: state.results ++ [result]}
    end)
  end

  @doc "Retrieves all stored test results, in arrival order."
  @spec get_results(GenServer.server()) :: [TestLens.Result.t()]
  def get_results(server \\ __MODULE__) do
    Agent.get(server, & &1.results)
  end

  # --- per-module results --------------------------------------------------

  @doc """
  Records a module-level event. `event` is a plain map with at least
  `:name` (atom) and `:event` (one of `:started`, `:finished`); `:file`
  and `:state` are optional and forwarded from `ExUnit.TestModule`.
  """
  @spec put_module_event(map(), GenServer.server()) :: :ok
  def put_module_event(event, server \\ __MODULE__) do
    Agent.update(server, fn state ->
      %{state | modules: state.modules ++ [event]}
    end)
  end

  @doc "Retrieves all stored module events, in arrival order."
  @spec get_module_events(GenServer.server()) :: [map()]
  def get_module_events(server \\ __MODULE__) do
    Agent.get(server, & &1.modules)
  end

  @doc "Returns the set of module names that emitted any event."
  @spec module_names(GenServer.server()) :: [atom()]
  def module_names(server \\ __MODULE__) do
    server
    |> get_module_events()
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc "Returns the most recent event for a given module name, or nil."
  @spec latest_module_event(atom(), GenServer.server()) :: map() | nil
  def latest_module_event(name, server \\ __MODULE__) do
    server
    |> get_module_events()
    |> Enum.reverse()
    |> Enum.find(&(&1.name == name))
  end

  # --- shared --------------------------------------------------------------

  @doc "Resets the store to an empty state."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    Agent.update(server, fn _ -> empty_state() end)
  end

  @doc "Returns the total count of stored results."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__) do
    length(get_results(server))
  end

  @doc """
  Returns the count of results with the given status. Statuses are
  `:passed | :failed | :skipped | :excluded | :invalid`.
  """
  @spec count_by_status(:passed | :failed | :skipped | :excluded | :invalid, GenServer.server()) ::
          non_neg_integer()
  def count_by_status(status, server \\ __MODULE__) do
    Enum.count(get_results(server), fn r -> r.status == status end)
  end

  # --- aliases -------------------------------------------------------------

  @doc "Alias for `put_result/2`."
  @spec put(TestLens.Result.t(), GenServer.server()) :: :ok
  def put(result, server \\ __MODULE__), do: put_result(result, server)

  @doc "Alias for `get_results/1`."
  @spec get(GenServer.server()) :: [TestLens.Result.t()]
  def get(server \\ __MODULE__), do: get_results(server)

  # --- private -------------------------------------------------------------

  defp empty_state, do: %{results: [], modules: []}
end
