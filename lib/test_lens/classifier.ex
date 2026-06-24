defmodule TestLens.Classifier do
  @moduledoc "Categorizes tests into types: unit, integration, phoenix, live_view, ecto, otp, etc."

  @adapters [
    TestLens.Adapters.LiveView,
    TestLens.Adapters.Phoenix,
    TestLens.Adapters.Ecto,
    TestLens.Adapters.OTP
  ]

  @failure_adapters [
    TestLens.FailureAdapters.Timeout,
    TestLens.FailureAdapters.Mock,
    TestLens.FailureAdapters.EctoConstraint,
    TestLens.FailureAdapters.EctoSandbox,
    TestLens.FailureAdapters.PhoenixRoute,
    TestLens.FailureAdapters.LiveViewRender,
    TestLens.FailureAdapters.ProcessExit,
    TestLens.FailureAdapters.MatchError,
    TestLens.FailureAdapters.FunctionClause,
    TestLens.FailureAdapters.CaseClause,
    TestLens.FailureAdapters.UndefinedFunction,
    TestLens.FailureAdapters.Assertion
    # NOTE: Unknown is the implicit fallback; it always matches.
  ]

  @type category ::
          :unit
          | :integration
          | :phoenix
          | :live_view
          | :ecto
          | :otp
          | :controller
          | :view
          | :channel
          | :unknown

  @type classification :: %{
          type: atom(),
          likely_layer: String.t(),
          plain_english: String.t(),
          common_causes: [String.t()],
          suggested_checks: [String.t()],
          default_severity: :critical | :other
        }

  @doc "Classifies an ExUnit.Test into a category."
  @spec classify(ExUnit.Test.t()) :: category()
  def classify(%ExUnit.Test{} = test) do
    tags = test.tags || %{}

    cond do
      Map.has_key?(tags, :integration) -> :integration
      Map.has_key?(tags, :unit) -> :unit
      true -> classify_with_adapters(test)
    end
  end

  defp classify_with_adapters(test) do
    Enum.find_value(@adapters, :unknown, fn adapter ->
      if adapter.match?(test) do
        adapter.category()
      else
        false
      end
    end)
  end

  @doc "Registers an adapter at the front of the priority list."
  @spec register_adapter(module(), category()) :: :ok
  def register_adapter(adapter_module, _category) when is_atom(adapter_module) do
    # Prepend user adapter to the list
    # We use a process dictionary to store the extended adapter list
    current = Process.get(:tl_adapters, @adapters)
    Process.put(:tl_adapters, [adapter_module | current])
    :ok
  end

  @doc "Returns the list of registered adapters."
  @spec registered_adapters() :: [module()]
  def registered_adapters do
    Process.get(:tl_adapters, @adapters)
  end

  @doc "Returns a human-readable label for a category."
  @spec category_label(category()) :: String.t()
  def category_label(category) do
    %{
      unit: "unit",
      integration: "integration",
      phoenix: "phoenix",
      live_view: "live_view",
      ecto: "ecto",
      otp: "otp",
      controller: "controller",
      view: "view",
      channel: "channel",
      unknown: "unknown"
    }
    |> Map.get(category, Atom.to_string(category))
  end

  @doc """
  Classifies a failure tuple {kind, reason, stacktrace} into a classification map.

  Walks the failure adapters in priority order; first adapter whose match?/1
  returns true wins. Returns unknown classification if no adapter matches.
  """
  @spec classify_failure({atom(), term(), list()}) :: classification()
  def classify_failure(failure) do
    adapters = Process.get(:tl_failure_adapters, @failure_adapters)

    Enum.find_value(adapters, unknown_details(), fn adapter ->
      if adapter.match?(failure), do: adapter.details()
    end)
  end

  @doc """
  Registers a user-defined failure adapter at the front of the priority list.

  User adapters take precedence over built-in adapters.
  """
  @spec register_failure_adapter(module()) :: :ok
  def register_failure_adapter(adapter_module) when is_atom(adapter_module) do
    # Prepend so the user adapter wins over built-ins.
    current = Process.get(:tl_failure_adapters, @failure_adapters)
    Process.put(:tl_failure_adapters, [adapter_module | current])
    :ok
  end

  defp unknown_details do
    TestLens.FailureAdapters.Unknown.details()
  end
end
