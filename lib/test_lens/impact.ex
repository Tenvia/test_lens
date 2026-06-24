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
  """
  @spec classify(TestLens.Result.t()) :: t()
  def classify(%TestLens.Result{} = r) do
    classify(r.file, r.tags, nil)
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
    # keys are relative to the consumer's cwd. Relativize before
    # comparing so the two share a common root.
    relative = if is_binary(file), do: Path.relative_to_cwd(file), else: file

    Enum.find_value(areas, fn {path, area} ->
      if String.starts_with?(relative, path), do: area
    end)
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
end
