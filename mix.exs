defmodule TestLens.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_lens,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      source_url: "https://github.com/testlens/test_lens",
      licenses: ["MIT"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    []
  end

  defp description do
    "Improved ExUnit output and tooling for Elixir, Phoenix, and OTP codebases."
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      maintainers: [],
      licenses: ["MIT"],
      links: %{
        GitHub: "https://github.com/testlens/test_lens"
      }
    ]
  end

  # `mix test.lens` should always run in :test env. Set here rather than as
  # `@preferred_cli_env` on the task module because that attribute is
  # deprecated on tasks since Elixir 1.19.
  def cli do
    [preferred_envs: ["test.lens": :test]]
  end
end
