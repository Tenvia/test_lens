defmodule TestLens.Impact do
  @moduledoc """
  Impact analysis: classify a test's impact level based on the project's
  `.test_lens.exs` configuration and the test's ExUnit tags.

  ## Project config supplies meaning. TestLens supplies structure.

  This module is a STRUCTURAL pipeline. The MEANING of "which paths
  map to which areas" and "which tags are critical" is supplied by
  `.test_lens.exs` in the consumer's project root, loaded via
  `TestLens.ProjectConfig`. TestLens does not assume any specific
  directory layout, tag set, or impact vocabulary — those come from
  the project.

  ## What `classify/3` returns

  ```elixir
  %TestLens.Impact{
    area: String.t() | nil,        # label from the matched area, or nil
    impact: :high | :medium | :low | :none,
    user_facing: boolean(),
    critical: boolean(),           # true if critical tag matched, OR area was high + user-facing
    reason: String.t()             # human-readable explanation
  }
  ```

  ## Priority rules

  1. **Critical tag override** — if any of the test's tags is in
     `config.critical_tags`, the result is `critical: true` with
     `impact: :high` and a `"tagged critical: ..."` reason. This
     wins over area matching.
  2. **Path match** — if the test's file path starts with any
     `config.areas` key, the matched area's data is used. The
     `critical` field is true if and only if the area has
     `impact: :high` AND `user_facing: true`.
  3. **Default** — no tag match, no path match: `area: nil,
     impact: :none, user_facing: false, critical: false,
     reason: "no matching area or tag"`.
  """

  @moduledoc since: "0.1.0"

  alias TestLens.ProjectConfig

  @type impact_level :: :high | :medium | :low | :none

  defstruct [:area, :impact, :user_facing, :critical, :reason]

  @type t :: %__MODULE__{
          area: String.t() | nil,
          impact: impact_level(),
          user_facing: boolean(),
          critical: boolean(),
          reason: String.t()
        }

  @doc """
  Classifies a test result (convenience wrapper for classify/3).
  Accepts a `TestLens.Result.t()` and extracts its `file` and `tags`.

  Resolution order for the project config:
    1. `Application.get_env(:test_lens, :project_config)` if it is a
       `%ProjectConfig{}` (set by `TestLens.Formatter.init/1` at the
       consumer's project root — the cwd where `.test_lens.exs` is
       reachable).
    2. `ProjectConfig.load_or_default/0` (reads `.test_lens.exs` from
       the current working directory).

  The first resolution path fixes the umbrella-project bug where
  the test process runs in the app cwd (e.g. `apps/saastle/`) but
  `.test_lens.exs` lives at the umbrella root; without the app-env
  fallback the test process would load an empty config.
  """
  @spec classify(TestLens.Result.t()) :: t()
  def classify(%TestLens.Result{} = r) do
    config = resolve_config()
    classify(r.file, r.tags, config)
  end

  @doc """
  Accepts a `TestLens.Result.t()` and an explicit `TestLens.ProjectConfig`.

  The caller (typically a formatter started at the consumer's project
  root, where `.test_lens.exs` is reachable) is responsible for
  loading the config. This is the recommended arity for use from
  reporters because the test process's cwd may differ from the
  config's cwd (e.g. in an umbrella project, the test runs in the
  app dir, but `.test_lens.exs` is at the umbrella root).
  """
  @spec classify(TestLens.Result.t(), ProjectConfig.t()) :: t()
  def classify(%TestLens.Result{} = r, %ProjectConfig{} = config) do
    classify(r.file, r.tags, config)
  end

  @doc """
  Classifies a test based on its file path, its ExUnit tags, and an
  optional `TestLens.ProjectConfig`. If `config` is `nil`, the
  `.test_lens.exs` file in the current working directory is loaded
  (with safe fallback to an empty config).

  Returns a `%TestLens.Impact{}` struct.
  """
  @spec classify(String.t() | nil, [atom()], ProjectConfig.t() | nil) :: t()
  def classify(file, tags, config)

  def classify(file, tags, nil) do
    classify(file, tags, ProjectConfig.load_or_default())
  end

  def classify(file, tags, %ProjectConfig{} = config) do
    do_classify(file, tags, config)
  end

  defp do_classify(file, tags, %ProjectConfig{critical_tags: ct} = config) do
    critical = Enum.filter(tags, &(&1 in ct))

    if critical != [] do
      %__MODULE__{
        area: nil,
        impact: :high,
        user_facing: true,
        critical: true,
        reason: "tagged critical: #{Enum.join(Enum.map(critical, &Atom.to_string/1), ", ")}"
      }
    else
      path_match(file, config)
    end
  end

  defp path_match(file, %ProjectConfig{areas: areas}) do
    case find_area(file, areas) do
      nil ->
        default_impact()

      area ->
        %__MODULE__{
          area: area.label,
          impact: area.impact,
          user_facing: area.user_facing,
          critical: area.impact == :high and area.user_facing,
          reason: ~s(matches area "#{area.label}")
        }
    end
  end

  def find_area(nil, _areas), do: nil

  def find_area(file, areas) do
    # ExUnit.TestModule.file is an absolute path; .test_lens.exs area
    # keys are relative to the directory holding the config (the
    # consumer's project root, which differs from the test-process
    # cwd in umbrella projects). Relativize the file against that
    # same root so the two share a common prefix basis.
    relative = relativize_for_areas(file)

    Enum.find_value(areas, fn {path, area} ->
      if String.starts_with?(relative, path), do: area
    end)
  end

  # Relativize `file` against the directory of the .test_lens.exs
  # that was loaded, when known. Falls back to `Path.relative_to_cwd/1`
  # when no source path is recorded (e.g. configs built via
  # `from_keyword/1` without specifying a file).
  #
  # Note: Path.relative_to/2's argument order is (file, base) — the
  # second argument is the base directory. The result is the first
  # argument's path relative to the second. Verified against Elixir 1.19.
  defp relativize_for_areas(file) when is_binary(file) do
    case area_config_source_dir() do
      nil -> Path.relative_to_cwd(file)
      "" -> Path.relative_to_cwd(file)
      source_dir -> Path.relative_to(file, source_dir)
    end
  end

  defp relativize_for_areas(file), do: file

  # The .test_lens.exs source path is stored as a sidecar key on the
  # project_config in the application environment. See
  # TestLens.ProjectConfig.load/1 and the mix task that publishes it.
  defp area_config_source_dir do
    case Application.get_env(:test_lens, :project_config_source_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end

  defp default_impact do
    %__MODULE__{
      area: nil,
      impact: :none,
      user_facing: false,
      critical: false,
      reason: "no matching area or tag"
    }
  end

  # ---------------------------------------------------------------------------
  # v0.1.0 contract stubs (unchanged)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a list of files changed since the given timestamp.

  This is a v0.1.0 STUB. It always returns an empty list. A real
  implementation will walk `git diff` output.
  """
  @spec changed_files_since(DateTime.t()) :: [String.t()]
  def changed_files_since(_since), do: []

  @doc """
  Returns the subset of results that are affected by a set of changed
  files.

  This is a v0.1.0 STUB. It always returns an empty list. A real
  implementation will map changed source files to likely-affected test
  modules.
  """
  @spec affected_tests([String.t()], [TestLens.Result.t()]) :: [TestLens.Result.t()]
  def affected_tests(_changed_files, _results), do: []

  # Private: resolve a project config for classify/1. Prefers the config
  # cached in the application environment by TestLens.Formatter (set at
  # the consumer's project root, where `.test_lens.exs` is reachable),
  # and falls back to loading from cwd. Without the app-env fallback,
  # umbrella projects would load an empty config because the test
  # process runs in the app cwd, not the umbrella root.
  defp resolve_config do
    case Application.get_env(:test_lens, :project_config) do
      %TestLens.ProjectConfig{} = config -> config
      _ -> ProjectConfig.load_or_default()
    end
  end
end
