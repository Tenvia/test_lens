defmodule TestLens.ClassifierTest do
  use ExUnit.Case, async: true

  alias TestLens.Classifier

  # Helper to build a minimal ExUnit.Test-like struct for classification.
  # ExUnit.Test fields: name, module, state, time, tags, logs, parameters (1.18+).
  # We only set module, name, tags.
  defp build(module, tags \\ %{}) do
    %ExUnit.Test{name: :some_test, module: module, state: nil, time: 0, tags: tags, logs: []}
  end

  test "tags :integration wins" do
    assert Classifier.classify(build(:"MyAppWeb.UserControllerTest", %{integration: true})) == :integration
  end

  test "tags :unit wins" do
    assert Classifier.classify(build(:"MyAppWeb.UserControllerTest", %{unit: true})) == :unit
  end

  test "module ending in Controller -> :phoenix" do
    assert Classifier.classify(build(:"MyAppWeb.UserControllerTest")) == :phoenix
  end

  test "module ending in LiveView -> :live_view" do
    assert Classifier.classify(build(:"MyAppWeb.PageLiveViewTest")) == :live_view
  end

  test "module containing Repo -> :ecto" do
    assert Classifier.classify(build(:"MyApp.UsersRepoTest")) == :ecto
  end

  test "module ending in GenServer -> :otp" do
    assert Classifier.classify(build(:"MyApp.WorkerGenServerTest")) == :otp
  end

  test "plain module -> :unknown" do
    assert Classifier.classify(build(:"MyApp.CalculatorTest")) == :unknown
  end

  test "category_label/1 for known categories" do
    for {atom, str} <- [
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
    ] do
      assert Classifier.category_label(atom) == str
    end
  end
end