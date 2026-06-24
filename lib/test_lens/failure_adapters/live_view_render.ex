defmodule TestLens.FailureAdapters.LiveViewRender do
  @moduledoc "Classifies Phoenix LiveView render/event/assertion-style failures."

  @live_view_modules [
    "Phoenix.LiveView.RenderError",
    "Phoenix.LiveView.FlashError",
    "Phoenix.LiveView.AsyncCallError",
    "Phoenix.LiveViewTransportError",
    "Phoenix.Component.NotImplementedError"
  ]

  def match?({_kind, %{__exception__: true, __struct__: struct}, _stacktrace}) do
    mod = to_string(struct)
    Enum.any?(@live_view_modules, &String.contains?(mod, &1))
  end

  def match?(_), do: false

  def details do
    %{
      type: :live_view_render,
      likely_layer: "LiveView rendering / event handling",
      plain_english:
        "A LiveView likely failed to render, an event likely did not behave as expected, or an assertion in the live page did not hold.",
      common_causes: [
        "template changed and assigns are stale",
        "missing or renamed event handler",
        "render crash in a child component",
        "process crash inside a LiveView lifecycle callback"
      ],
      suggested_checks: [
        "inspect the failing LiveView and its assigns",
        "rerun the exact file",
        "check child components for stale inputs"
      ],
      default_severity: :other
    }
  end
end
