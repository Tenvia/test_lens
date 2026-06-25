defmodule TestLens.TelemetryBridge do
  @moduledoc """
  Attaches to the consumer's `:telemetry` stream during a TestLens run
  and stores a bounded ring buffer of selected events.

  ## Scope

  TestLens attaches to four event-name prefixes that map to OTP-level
  lifecycle signals:

    * `[:supervisor, ...]` — child start, restart, terminate.
    * `[:gen_server, ...]` — cast/call/info logging (when present).
    * `[:oban, ...]` — job lifecycle.
    * `[:broadway, ...]` — batch lifecycle.

  Anything outside these prefixes is ignored, regardless of who emits
  it. The consumer's stream is preserved — TestLens never detaches
  handlers it did not attach.

  ## Bounded buffer

  The bridge keeps at most `ring_size` events (default `64`). When the
  buffer is full, the oldest event is dropped. `events/1` returns the
  buffered events in arrival order.

  ## Lifecycle

    * `start_link/1` — starts the bridge and attaches a private
      `:telemetry` handler. Each bridge has a unique suffix, so multiple
      bridges can coexist in the same VM (useful for tests and for
      multi-runner setups).
    * `stop/1` — detaches the handler and terminates the process.
    * `events/1` — returns the buffered events in arrival order.

  In TestLens's production usage, the Formatter starts the bridge on
  `:suite_started` (when `--snapshot` is enabled) and stops it on
  `:suite_finished`.
  """

  use GenServer

  @handler_id_base "test-lens-telemetry-bridge"
  @ring_size 64
  @prefixes [
    [:supervisor],
    [:gen_server],
    [:oban],
    [:broadway]
  ]

  @event_names [
    [:supervisor, :child, :started],
    [:supervisor, :child, :restart],
    [:supervisor, :child, :terminated],
    [:gen_server, :cast],
    [:gen_server, :call],
    [:gen_server, :info],
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:broadway, :batch, :start],
    [:broadway, :batch, :stop],
    [:broadway, :batch, :exception]
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Returns the base telemetry handler id used by the bridge."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id_base

  @doc "Returns the configured ring-buffer size."
  @spec ring_size() :: pos_integer()
  def ring_size, do: @ring_size

  @doc "Starts the bridge and attaches the telemetry handler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    suffix = Keyword.get(opts, :suffix, default_suffix())
    name = Keyword.get(opts, :name, name_for(suffix))
    handler_id = handler_id_for(suffix)

    # `:name` is a GenServer start option, not an init arg. We forward
    # it explicitly so the bridge is registered under its atom name.
    start_opts = Keyword.take(opts, [:name])

    init_opts =
      opts
      |> Keyword.put(:suffix, suffix)
      |> Keyword.put(:name, name)
      |> Keyword.put(:handler_id, handler_id)

    GenServer.start_link(__MODULE__, init_opts, start_opts)
  end

  @doc "Stops the bridge and detaches the telemetry handler."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @doc "Returns the buffered events in arrival order."
  @spec events(GenServer.server()) :: [map()]
  def events(server) do
    GenServer.call(server, :events)
  end

  @doc "Returns a count of buffered events."
  @spec event_count(GenServer.server()) :: non_neg_integer()
  def event_count(server) do
    GenServer.call(server, :count)
  end

  @doc """
  Returns `true` when the given event-name list starts with one of
  the prefixes the bridge listens for.
  """
  @spec event_matches?([atom()]) :: boolean()
  def event_matches?(event_name) when is_list(event_name) and event_name != [] do
    Enum.any?(@prefixes, fn prefix ->
      EventNameMatch.match?(prefix, event_name)
    end)
  end

  def event_matches?(_), do: false

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    suffix = Keyword.fetch!(opts, :suffix)
    name = Keyword.fetch!(opts, :name)
    handler_id = Keyword.fetch!(opts, :handler_id)
    registry_name = registry_name_for(suffix)

    state = %{
      ring: :queue.new(),
      ring_size: Keyword.get(opts, :ring_size, @ring_size),
      attached: false,
      handler_id: handler_id,
      registry_name: registry_name,
      name: name
    }

    # `:telemetry` is declared `runtime: false` so the application is
    # NOT auto-started when TestLens is loaded. We start it here, on
    # demand, so the handler table exists when we try to attach. This
    # is a no-op (returns `{:ok, []}`) when `:telemetry` is already
    # started or when the app cannot be found.
    _ = Application.ensure_all_started(:telemetry)

    # The actual `Process.register` and `Registry.start_link` happen
    # in `handle_continue/2`, which runs in the GenServer's own process
    # after `init/1` returns. This is critical: `init/1` runs in a
    # temporary spawn process, so any pid captured here is the wrong
    # process and any `Process.register` call here registers the wrong
    # pid under our atom name.

    {:ok, state, {:continue, :attach}}
  end

  @impl true
  def handle_continue(:attach, state) do
    # Start a private Registry for this bridge.
    case Registry.start_link(keys: :duplicate, name: state.registry_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Registry.register(state.registry_name, :handler, nil) do
      {:ok, _} ->
        # Pass the bridge's pid as the telemetry handler's config arg.
        # `:telemetry` exposes the config as the 4th argument to the
        # handler closure, so we don't need to close over `self/0` or
        # rely on a registry lookup at dispatch time. When the bridge
        # dies, the registry entry is removed automatically, and any
        # in-flight handler dispatch checks `Process.alive?/1` to
        # drop events meant for a dead bridge.
        attach_telemetry_handler(state.handler_id, self())
        {:noreply, %{state | attached: true}}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:events, _from, state) do
    {:reply, :queue.to_list(state.ring), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :queue.len(state.ring), state}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    ring =
      case :queue.len(state.ring) >= state.ring_size do
        true ->
          {{:value, _dropped}, ring_tail} = :queue.out(state.ring)
          :queue.in(event, ring_tail)

        false ->
          :queue.in(event, state.ring)
      end

    {:noreply, %{state | ring: ring}}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | ring: :queue.new()}}
  end

  @impl true
  def handle_info({__MODULE__, {:event, event_name, measurements, metadata}}, state) do
    event = %{
      "event" => Enum.map_join(event_name, ".", &Atom.to_string/1),
      "measurements" => stringify_value(measurements),
      "metadata" => stringify_value(metadata)
    }

    ring =
      case :queue.len(state.ring) >= state.ring_size do
        true ->
          {{:value, _dropped}, ring_tail} = :queue.out(state.ring)
          :queue.in(event, ring_tail)

        false ->
          :queue.in(event, state.ring)
      end

    {:noreply, %{state | ring: ring}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.attached do
      _ = detach_telemetry_handler(state.handler_id)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Telemetry handler
  # ---------------------------------------------------------------------------

  defp attach_telemetry_handler(handler_id, bridge_pid) do
    if telemetry_available?() do
      # Route events to the bridge pid via the config argument. We
      # pass the bridge pid directly so the handler closure doesn't
      # need to close over `self/0` (which would be the dispatcher's
      # pid, not the bridge's). When the bridge dies, in-flight
      # handler dispatches check `Process.alive?/1` and drop the event
      # silently, preventing cross-bridge event contamination.
      handler = fn event_name, measurements, metadata, config ->
        case config do
          pid when is_pid(pid) ->
            if Process.alive?(pid) do
              send(pid, {__MODULE__, {:event, event_name, measurements, metadata}})
            else
              :ok
            end

          _ ->
            :ok
        end
      end

      :telemetry.attach_many(handler_id, @event_names, handler, bridge_pid)
    end
  rescue
    _ -> :ok
  end

  defp detach_telemetry_handler(handler_id) do
    if telemetry_available?() do
      :telemetry.detach(handler_id)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp telemetry_available? do
    Code.ensure_loaded?(:telemetry)
  end

  # ---------------------------------------------------------------------------
  # Naming helpers
  # ---------------------------------------------------------------------------

  defp default_suffix, do: System.unique_integer([:positive])
  def name_for(suffix), do: :"#{@handler_id_base}.#{suffix}"
  def handler_id_for(suffix), do: "#{@handler_id_base}.#{suffix}"
  defp registry_name_for(suffix), do: :"#{@handler_id_base}.Registry.#{suffix}"

  # ---------------------------------------------------------------------------
  # Value normalization
  # ---------------------------------------------------------------------------

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)

  defp stringify_value(v) when is_atom(v) and v not in [nil, true, false],
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string_key(k), stringify_value(v)} end)
  end

  defp stringify_keys(other), do: other

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: k
end

defmodule EventNameMatch do
  @moduledoc false

  @doc false
  def match?(prefix, event_name) when is_list(prefix) and is_list(event_name) do
    length(prefix) <= length(event_name) and
      Enum.zip(prefix, event_name) |> Enum.all?(fn {p, e} -> p == e end)
  end

  def match?(_, _), do: false
end
