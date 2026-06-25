defmodule TestLens.ProjectConfig do
  # The canonical `.test_lens.exs` example lives in
  # `TestLens.ProjectConfig.Example.text/0` so the test suite can eval
  # the same string the docs render. See that module for the rationale.

  alias TestLens.ProjectConfig.Example

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
    areas: %{                    # optional, default: %{}
      String.t() => [            # path prefix (e.g. "test/example_app/accounts")
        label: String.t(),       # required
        impact: :high | :medium | :low | :none,  # default: :none
        user_facing: boolean()   # default: false
      ]
    },
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
    to `"Unnamed"`. A list of `{path, [descriptor]}` tuples is also
    accepted; the loader normalises both forms to a map.
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
  #{Example.text()}
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

  @doc """
  Like `load_or_default/1`, but walks up the directory tree from
  the starting path looking for a `.test_lens.exs` file. This is
  the recommended entry point for tooling that may be invoked from
  a subdirectory of the consumer's project (e.g. a Mix task in an
  Elixir umbrella, where the task's cwd is the app dir but the
  config lives at the umbrella root).

  Resolution order:
    1. `<start>/.test_lens.exs` if `start` is a directory
    2. `<start>` itself if it is a regular file (in case the caller
       passed a path to the file directly)
    3. Walk up: `<parent>/.test_lens.exs`, `<parent>/.test_lens.exs`, ...
       until either a file is found or the filesystem root is reached.
    4. On miss, return an empty `%ProjectConfig{}` (same fallback as
       `load_or_default/1`).

  The `start` argument defaults to the current working directory.

  Side effect: on success, publishes the directory containing the
  found config file to the application environment under
  `:test_lens, :project_config_source_dir`. `TestLens.Impact.find_area/2`
  reads this key to relativize test file paths against the same root
  the config was loaded from, which is the only way area-key prefix
  matches work in umbrella projects.
  """
  @spec load_or_walk(Path.t()) :: t()
  def load_or_walk(start \\ File.cwd!()) do
    case find_config_file(start) do
      nil ->
        Application.delete_env(:test_lens, :project_config_source_dir)
        %__MODULE__{}

      path ->
        publish_source_dir(path)
        load_or_default(path)
    end
  end

  @doc """
  Like `load/1`, but walks up the directory tree from the starting
  path looking for a `.test_lens.exs` file. Returns `{:ok, t()}`
  on success and `{:error, reason}` on miss.
  """
  @spec load_walk(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load_walk(start \\ File.cwd!()) do
    case find_config_file(start) do
      nil -> {:error, "No .test_lens.exs found at #{start} or any parent directory"}
      path -> load(path)
    end
  end

  defp publish_source_dir(path) do
    Application.put_env(:test_lens, :project_config_source_dir, Path.dirname(path))
  end

  defp find_config_file(start) do
    cond do
      File.regular?(start) ->
        start

      File.dir?(start) ->
        candidate = Path.join(start, ".test_lens.exs")

        if File.regular?(candidate) do
          candidate
        else
          parent = Path.dirname(start)

          if parent == start do
            nil
          else
            find_config_file(parent)
          end
        end

      true ->
        nil
    end
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

  # `for {k, v} <- map` iterates a map the same way as a list of
  # {key, value} tuples, so the body of this clause is identical to
  # the list clause. The schema doc says `areas` is a "map" — this
  # clause honours the documented contract.
  defp normalize_areas(areas) when is_map(areas) do
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

  defp normalize_tags(tags) when is_list(tags),
    do: Enum.filter(tags, &is_atom/1) |> Enum.reject(&is_nil/1)

  defp normalize_tags(_), do: []

  defp validate_impact(impact) when impact in @valid_impacts, do: impact
  defp validate_impact(_), do: :none

  defp to_string_safe(nil, default), do: default
  defp to_string_safe(s, _) when is_binary(s), do: s
  defp to_string_safe(atom, _) when is_atom(atom), do: Atom.to_string(atom)
  defp to_string_safe(other, _), do: to_string(other)
end
