defmodule TestLens.FailureAdapters.ProcessExit do
  @moduledoc "Classifies GenServer / process exit failures (kind: :exit)."

  def match?({:exit, _reason, _stacktrace}), do: true
  def match?(_), do: false

  def details do
    %{
      type: :process_exit,
      likely_layer: "Process / OTP",
      plain_english:
        "A process likely exited unexpectedly, was killed, or its owner raised while supervising it.",
      common_causes: [
        "crash in GenServer.init/1 or a callback",
        "a linked process died",
        "Task awaited on a dead pid",
        "explicit Process.exit/2"
      ],
      suggested_checks: [
        "inspect the crash log",
        "check linked processes",
        "rerun the exact file"
      ],
      default_severity: :critical
    }
  end
end
