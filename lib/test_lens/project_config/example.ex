defmodule TestLens.ProjectConfig.Example do
  @moduledoc false
  @doc """
  The canonical `.test_lens.exs` example, exposed as a function so the
  test suite can eval the same string the docs render. Keeping it in
  its own module (rather than as a module attribute on
  `TestLens.ProjectConfig`) avoids the gotcha that interpolation in a
  moduledoc consumes the attribute, and lets the test eval the example
  with a single `text/0` call.
  """

  @spec text() :: String.t()
  def text do
    """
    [
      project: "ExampleApp",
      areas: %{
        "test/example_app/accounts" => [
          label: "Accounts",
          impact: :high,
          user_facing: true
        ],
        "test/example_app_web/live" => [
          label: "LiveView/UI",
          impact: :high,
          user_facing: true
        ],
        "test/example_app_workers" => [
          label: "Background jobs",
          impact: :medium,
          user_facing: false
        ]
      },
      critical_tags: [:payment, :security, :data_integrity]
    ]
    """
  end
end
