defmodule TestLens.Adapters.OTP do
  @moduledoc "OTP behaviour adapter: GenServer, Supervisor, etc."
  @suffixes ["Worker", "GenServer", "GenServerTest", "Supervisor", "SupervisorTest", "GenStateMachine", "GenStateMachineTest", "GenEvent", "GenEventTest", "GenStage", "GenStageTest", "Application", "ApplicationTest"]

  @spec category :: :otp
  def category, do: :otp

  @spec match?(ExUnit.Test.t()) :: boolean()
  def match?(%ExUnit.Test{module: mod, tags: tags}) when not is_nil(mod) do
    name = mod |> Atom.to_string() |> String.trim_leading("Elixir.")
    has_suffix = Enum.any?(@suffixes, &String.ends_with?(name, &1))
    has_suffix or Map.has_key?(tags, :otp)
  end

  def match?(_), do: false
end