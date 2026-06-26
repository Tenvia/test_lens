defmodule TestLens.Architecture.Rules.RegistryNaming do
  @moduledoc """
  Flags registered process names that don't follow the
  `Elixir.<App>.<Role>` convention (e.g. `Elixir.MyApp.Billing.Worker`).
  Ad-hoc names like `:payment_worker` make :observer grep harder and
  hide ownership at runtime.

  ## Detection

  In v4.0 we can't introspect live processes from the formatter, so we
  detect candidates via a static AST scan of every `.ex` under
  `lib_root`: any `Process.register(pid, name)` where `name` is a bare
  atom literal that does not start with `Elixir.`.
  """

  alias TestLens.Architecture.Finding

  @rule_id :registry_naming

  @doc """
  Run the registry-naming rule. Returns one finding per non-conventional
  `Process.register/2` literal.
  """
  @spec run(TestLens.OTPTopology.t(), Path.t() | nil) :: [Finding.t()]
  def run(%TestLens.OTPTopology{} = _topology, lib_root \\ nil) do
    if lib_root == nil do
      []
    else
      lib_root
      |> list_ex_files()
      |> Enum.flat_map(&scan_file/1)
    end
  end

  defp list_ex_files(root) do
    case File.ls(root) do
      {:ok, entries} when is_list(entries) ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          cond do
            File.regular?(path) and String.ends_with?(path, ".ex") -> [path]
            File.dir?(path) -> list_ex_files(path)
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp scan_file(path) do
    try do
      ast = Code.string_to_quoted!(File.read!(path))
      walk(path, ast)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp walk(path, ast) do
    {_, findings} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Process]}, :register]}, _, [_pid, name]} = node, acc ->
          if conventional?(name) do
            {node, acc}
          else
            {node, [finding(name, path) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    findings
  end

  defp conventional?({:__aliases__, _, aliases}) do
    case Module.concat(aliases) do
      mod when is_atom(mod) ->
        mod_str = Atom.to_string(mod)
        String.starts_with?(mod_str, "Elixir.")

      _ ->
        false
    end
  end

  # `Process.register(pid, __MODULE__)` expands to `__MODULE__` at compile
  # time and resolves to the calling module — always `Elixir.<App>.<Role>`.
  defp conventional?({:__MODULE__, _, _}), do: true

  defp conventional?(_), do: false

  defp finding(name, path) do
    name_str = inspect(name)

    Finding.from(
      @rule_id,
      "#{name_str}-#{path}",
      {:info, 0.60},
      "Process.register/2 with non-conventional name #{name_str}",
      "Ad-hoc registered names hide ownership and make :observer grep harder. Use an `Elixir.<App>.<Role>` module alias.",
      "Switch to `Process.register(pid, __MODULE__)` or an explicit `Elixir.<App>.<Role>` alias.",
      %{file: path, line: nil},
      []
    )
  end
end
