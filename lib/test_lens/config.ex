defmodule TestLens.Config do
  @moduledoc "Configuration for TestLens output and behavior."

  defstruct format: :tty,
            output: :stdout,
            color: true,
            impact: false,
            rerun: false,
            json: false,
            json_file: nil,
            html: false,
            html_file: nil,
            extras: []

  @type t :: %__MODULE__{
          format: :tty | :json | :html,
          output: :stdout | Path.t(),
          color: boolean(),
          impact: boolean(),
          rerun: boolean(),
          json: boolean(),
          json_file: Path.t() | nil,
          html: boolean(),
          html_file: Path.t() | nil,
          extras: keyword()
        }

  @doc "Returns a Config struct with all default values."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc "Builds a Config from parsed option parser keywords."
  @spec from_option_parser(keyword()) :: t()
  def from_option_parser(opts) when is_list(opts) do
    if opts == [] or opts == nil do
      defaults()
    else
      defaults()
      |> apply_json_opt(opts)
      |> apply_color_opts(opts)
      |> apply_json_file_opt(opts)
      |> apply_html_opt(opts)
      |> apply_html_file_opt(opts)
      |> normalize()
    end
  end

  def from_option_parser(_), do: defaults()

  defp apply_json_opt(config, opts) do
    if Keyword.get(opts, :json, false) do
      %{config | json: true}
    else
      config
    end
  end

  defp apply_json_file_opt(config, opts) do
    case Keyword.get(opts, :json_file) do
      nil -> config
      path -> %{config | json_file: path}
    end
  end

  defp apply_html_opt(config, opts) do
    if Keyword.get(opts, :html, false) do
      %{config | html: true}
    else
      config
    end
  end

  defp apply_html_file_opt(config, opts) do
    case Keyword.get(opts, :html_file) do
      nil -> config
      path -> %{config | html_file: path}
    end
  end

  defp apply_color_opts(config, opts) do
    cond do
      Keyword.get(opts, :no_color, false) -> %{config | color: false}
      Keyword.get(opts, :color, nil) == true -> %{config | color: true}
      true -> config
    end
  end

  @doc "Normalizes config: if json is true, forces format to :json; if html is true, forces format to :html."
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{html: true} = config), do: %{config | format: :html}
  def normalize(%__MODULE__{json: true} = config), do: %{config | format: :json}
  def normalize(config), do: config
end
