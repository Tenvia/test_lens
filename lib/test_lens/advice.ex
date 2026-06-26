defmodule TestLens.Advice do
  @moduledoc """
  Builds and writes the TestLens **architecture advisor artifact**.

  A separate JSON document that complements the agent artifact. The
  advisor walks the project's OTP topology (via `TestLens.OTPTopology`)
  and source AST (via `lib_root`) and emits a flat list of findings
  ranked by severity and confidence.

  ## Schema (`schema_version: "4.0"`)

  Top-level keys:

    * `schema_version`
    * `test_lens_version`
    * `project`
    * `run` — command, cwd, elixir/otp version
    * `totals` — counts by severity
    * `findings` — array of finding objects
    * `safety` — excluded fields and privacy notes
  """

  alias TestLens.Architecture
  alias TestLens.Architecture.Finding
  alias TestLens.JSONReport
  alias TestLens.OTPTopology
  alias TestLens.ProjectConfig

  @default_path "_build/test_lens/advice.json"
  @schema_version "4.0"

  @doc "Returns the default artifact path."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc "Returns the JSON `schema_version` string emitted by this build."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  Build the advisor artifact from a topology + lib_root.

  `lib_root` is the project's `lib/` directory. When `nil`, only
  topology-derived rules fire.
  """
  @spec build(OTPTopology.t(), Path.t() | nil) :: map()
  def build(%OTPTopology{} = topology, lib_root \\ nil) do
    findings = Architecture.run(topology, lib_root)

    %{
      "schema_version" => @schema_version,
      "test_lens_version" => TestLens.version(),
      "project" => ProjectConfig.load_or_default().project,
      "run" => run_info(),
      "totals" => totals(findings),
      "findings" => Enum.map(findings, &Finding.to_map/1),
      "safety" => safety_block()
    }
  end

  @doc """
  Encode the artifact to a JSON string. Delegates to
  `TestLens.JSONReport.encode/1` for parity with the other artifacts.
  """
  @spec encode(map()) :: String.t()
  def encode(artifact), do: JSONReport.encode(artifact)

  @doc """
  Build and write the artifact to `path`. Creates parent directories
  if they do not exist.
  """
  @spec write(Path.t(), OTPTopology.t(), Path.t() | nil) :: :ok | {:error, term()}
  def write(path, topology, lib_root \\ nil) do
    payload = encode(build(topology, lib_root))

    try do
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, payload)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_info do
    %{
      "command" => "mix test.lens",
      "cwd" => File.cwd!(),
      "elixir" => System.version()
    }
  end

  defp totals(findings) do
    %{
      "total" => length(findings),
      "error" => Enum.count(findings, fn f -> f.severity == :error end),
      "warn" => Enum.count(findings, fn f -> f.severity == :warn end),
      "info" => Enum.count(findings, fn f -> f.severity == :info end)
    }
  end

  defp safety_block do
    %{
      "excluded_fields" => ["env", "mix_project_config", "application_config"],
      "notes" =>
        "The advisor artifact contains OTP topology findings only. " <>
          "It does not include environment variables, application configuration, " <>
          "raw message payloads, or any test-time failure data. Findings are " <>
          "static and derived from AST analysis + supervisor introspection at " <>
          "test-time; they should be reviewed before acting."
    }
  end
end
