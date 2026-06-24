defmodule TestLens.ProjectConfig do
  @moduledoc """
  Loads and validates a `.test_lens.exs` file from the consumer's project root.

  ## Project config supplies meaning. TestLens supplies structure.

  This module is the loader and validator for `.test_lens.exs`,
  the project-level file that tells TestLens which test file paths
  belong to which *areas* of the codebase, and which ExUnit tags
  should be treated as *critical*.

  TestLens provides the STRUCTURE: the schema definitions, the loader,
  the validator, and the normaliser. The MEANING — which paths map to
  which areas, which tags are critical, what impact levels mean in your
  project — is supplied by the consumer via their `.test_lens.exs` file.

  ## Schema

  A `.test_lens.exs` file is a plain Elixir keyword list. The full
  schema:

  ```elixir
  [
    project: String.t(),         # optional, informational only
    areas: [                     # optional, default: []
      String.t() => [            # path prefix (e.g. "test/example_app/accounts")
        label: String.t(),       # required
        impact: :high | :medium | :low | :none,  # default: :none
        user_facing: boolean()   # default: false
      ]
    ],
    critical_tags: [atom()]      # optional, default: []
  ]
  ```

  ### Fields

  - `project` — an optional free-form string naming your application.
    TestLens does not use this field; it is purely informational.
  - `areas` — a map from path prefix strings to area descriptor
    keyword lists. A test file's path is matched against the prefixes
    using `String.starts_with?/2`. The first matching prefix wins (no
    glob expansion). Areas with invalid or missing `:label` fall back
    to `"Unnamed"`.
  - `critical_tags` — a list of ExUnit tag atoms. When a test carries
    one of these tags it is marked `critical: true` regardless of
    which area (if any) its file path matches.

  ## Loading semantics

  `load/1` and `load_or_default/1` never raise.

  - Missing file → `{:ok, %ProjectConfig{}}` (empty config).
  - File exists but cannot be read → `{:error, reason}`.
  - File contains invalid Elixir syntax → `{:error, "Invalid Elixir syntax ..."}`.
  - File evaluates to a non-list → `{:error, "Config must be a keyword list ..."}`.
  - File is otherwise valid but has an invalid shape → best-effort
    normalisation; unknown keys are ignored, bad impact values fall
    back to `:none`.

  `load_or_default/1` calls `load/1` and returns an empty config with
  a warning on any error. This is the function the rest of TestLens
  should use internally; tests should use `load/1` to assert on the
  error path.

  ## Example `.test_lens.exs`

  ```elixir
  [
    project: "ExampleApp",
    areas: [
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
      "test/example_app/workers" => [
        label: "Background jobs",
        impact: :medium,
        user_facing: false
      ]
    ],
    critical_tags: [:payment, :security, :data_integrity]
  ]
  ```
  """

  @moduledoc since: "0.1.0"

  defstruct [:project, areas: %{}, critical_tags: []]

  @type area :: %{
    label: String.t(),
    impact: :high | :medium | :low | :none,
    user_facing: boolean()
  }

  @type t :: %__MODULE__{
    project: String.t() | nil,
    areas: %{optional(String.t()) => area()},
    critical_tags: [atom()]
  }

  @valid_impacts [:high, :medium, :low, :none]

  @doc """
  Loads and validates a `.test_lens.exs` file from `path`
  (default `".test_lens.exs"` relative to the current working directory).

  Returns `{:ok, %ProjectConfig{}}` on success — including the case
  where the file does not exist (in which case the config is empty).

  Returns `{:error, reason}` if the file exists but cannot be read,
  contains invalid Elixir, or has an invalid shape.

  This function NEVER raises. It is safe to call from any code path.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path \\ ".test_lens.exs") do
    case File.read(path) do
      {:ok, content} ->
        try do
          {raw, _binding} = Code.eval_string(content)
          from_keyword(raw)
        rescue
          e in [SyntaxError, TokenMissingError] ->
            {:error, "Invalid Elixir syntax in #{path}: #{Exception.message(e)}"}
          e ->
            {:error, "Error evaluating #{path}: #{Exception.message(e)}"}
        catch
          kind, reason ->
            {:error, "Error evaluating #{path}: #{inspect(kind)} #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %__MODULE__{}}

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Like `load/1` but returns an empty config (and silently swallows
  errors) on failure. Logs a warning to `:stderr` if loading failed.

  This is the function the rest of TestLens should use internally;
  tests should use `load/1` to assert on the error path.
  """
  @spec load_or_default(Path.t()) :: t()
  def load_or_default(path \\ ".test_lens.exs") do
    case load(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        IO.warn("[TestLens] could not load #{path}: #{reason}", [])
        %__MODULE__{}
    end
  end

  @doc """
  Normalises a raw keyword list (as read from a `.test_lens.exs`
  file) into a `%ProjectConfig{}` struct. Unknown keys are ignored.
  Missing keys use defaults. Invalid impact values fall back to `:none`.

  Useful for constructing test fixtures.
  """
  @spec from_keyword(keyword() | any()) :: {:ok, t()} | {:error, String.t()}
  def from_keyword(raw) when is_list(raw) do
    project = Keyword.get(raw, :project)
    areas = normalize_areas(Keyword.get(raw, :areas, []))
    critical_tags = normalize_tags(Keyword.get(raw, :critical_tags, []))
    {:ok, %__MODULE__{project: project, areas: areas, critical_tags: critical_tags}}
  end

  def from_keyword(not_a_list) do
    {:error, "Config must be a keyword list, got: #{inspect(not_a_list)}"}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_areas(areas) when is_list(areas) do
    for {path, area} <- areas,
        is_binary(path) and is_list(area),
        into: %{},
        do: {path, normalize_area(area)}
  end

  defp normalize_areas(_), do: %{}

  defp normalize_area(area) do
    %{
      label: Keyword.get(area, :label) |> to_string_safe("Unnamed"),
      impact: Keyword.get(area, :impact, :none) |> validate_impact(),
      user_facing: Keyword.get(area, :user_facing, false)
    }
  end

  defp normalize_tags(tags) when is_list(tags), do: Enum.filter(tags, &is_atom/1) |> Enum.reject(&is_nil/1)
  defp normalize_tags(_), do: []

  defp validate_impact(impact) when impact in @valid_impacts, do: impact
  defp validate_impact(_), do: :none

  defp to_string_safe(nil, default), do: default
  defp to_string_safe(s, _) when is_binary(s), do: s
  defp to_string_safe(atom, _) when is_atom(atom), do: Atom.to_string(atom)
  defp to_string_safe(other, _), do: to_string(other)
end
