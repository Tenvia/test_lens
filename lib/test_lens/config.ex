defmodule TestLens.Config do
  @moduledoc "Configuration for TestLens output and behavior."

  defstruct format: :tty,
            output: :stdout,
            color: true,
            json: false,
            json_file: nil,
            html: false,
            html_file: nil,
            agent: false,
            agent_file: nil,
            snapshot: false,
            snapshot_dir: nil,
            advise: false,
            advise_file: nil,
            dashboard_port: nil,
            extras: []

  @type t :: %__MODULE__{
          format: :tty | :json | :html,
          output: :stdout | Path.t(),
          color: boolean(),
          json: boolean(),
          json_file: Path.t() | nil,
          html: boolean(),
          html_file: Path.t() | nil,
          agent: boolean(),
          agent_file: Path.t() | nil,
          snapshot: boolean(),
          snapshot_dir: Path.t() | nil,
          advise: boolean(),
          advise_file: Path.t() | nil,
          dashboard_port: non_neg_integer() | nil,
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
      |> apply_agent_opt(opts)
      |> apply_agent_file_opt(opts)
      |> apply_snapshot_opt(opts)
      |> apply_snapshot_dir_opt(opts)
      |> apply_advise_opt(opts)
      |> apply_advise_file_opt(opts)
      |> apply_dashboard_port_opt(opts)
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

  defp apply_agent_opt(config, opts) do
    if Keyword.get(opts, :agent, false) do
      %{config | agent: true}
    else
      config
    end
  end

  defp apply_agent_file_opt(config, opts) do
    case Keyword.get(opts, :agent_file) do
      nil -> config
      path -> %{config | agent_file: path}
    end
  end

  defp apply_snapshot_opt(config, opts) do
    if Keyword.get(opts, :snapshot, false) do
      %{config | snapshot: true}
    else
      config
    end
  end

  defp apply_snapshot_dir_opt(config, opts) do
    case Keyword.get(opts, :snapshot_dir) do
      nil -> config
      path -> %{config | snapshot_dir: path}
    end
  end

  defp apply_advise_opt(config, opts) do
    if Keyword.get(opts, :advise, false) do
      %{config | advise: true}
    else
      config
    end
  end

  defp apply_advise_file_opt(config, opts) do
    case Keyword.get(opts, :advise_file) do
      nil -> config
      path -> %{config | advise_file: path}
    end
  end

  defp apply_dashboard_port_opt(config, opts) do
    case Keyword.get(opts, :dashboard_port) do
      nil -> config
      port when is_integer(port) and port > 0 -> %{config | dashboard_port: port}
      _ -> config
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
