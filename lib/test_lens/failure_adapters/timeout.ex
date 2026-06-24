defmodule TestLens.FailureAdapters.Timeout do
  @moduledoc "Classifies timeout-style failures (exits with :timeout, or assertions about timeouts)."

  def match?({:exit, :timeout, _stacktrace}), do: true
  def match?({:exit, {:timeout, _}, _stacktrace}), do: true

  def match?({:error, %ExUnit.AssertionError{} = reason, _stacktrace}) do
    message = reason.message
    is_timeout_message = is_binary(message) and String.contains?(message, "timeout")
    is_timeout_left = is_list(reason.left) and :lists.member(:timeout, reason.left)
    is_timeout_message or is_timeout_left
  end

  def match?(_), do: false

  def details do
    %{
      type: :timeout,
      likely_layer: "Async / I/O",
      plain_english: "An operation likely did not complete within its time budget.",
      common_causes: [
        "possible deadlock in a process",
        "possible missing message",
        "slower CI hardware",
        "external service possibly unavailable"
      ],
      suggested_checks: [
        "check process mailbox",
        "check external service availability",
        "increase the timeout for this test"
      ],
      default_severity: :critical
    }
  end
end