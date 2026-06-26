defmodule Mix.Tasks.Lens.Serve do
  @moduledoc """
  Serves the TestLens artifacts directory as a static SPA over HTTP.

  This task is **dev-time only**. It refuses to run outside `Mix.env() == :dev`.
  In any other environment the task aborts with a clear error message.

  ## Usage

      mix lens.serve                       # port 4000, _build/test_lens
      mix lens.serve --port 4100           # override port
      mix lens.serve --dir tmp/test_lens   # override artifact directory

  The server is a small HTTP listener built on `:inets` (no new
  dependencies). It serves files with reasonable MIME types and
  defaults to `_build/test_lens/`. Stop with `Ctrl-C` (SIGINT).

  ## Why `:inets`?

  `:inets` ships with Erlang/OTP and provides a working HTTP server
  for static files with zero new runtime dependencies. v4.0 ships with
  `:inets` for that reason. v4.1 may swap to `:bandit` once it's
  stable as a default Elixir dep.
  """

  use Mix.Task

  @shortdoc "Serve TestLens artifacts as a static SPA over HTTP."

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :dev do
      Mix.shell().error("mix lens.serve is dev-time only. Current env: #{Mix.env()}.")
      Mix.shell().error("Run with MIX_ENV=dev mix lens.serve, or use a different tool.")
      exit({:shutdown, 1})
    end

    {parsed, _, invalid} = OptionParser.parse(args, strict: [port: :integer, dir: :string])

    if invalid != [] do
      raise ArgumentError, "Invalid options: #{inspect(invalid)}"
    end

    port = Keyword.get(parsed, :port, 4000)
    dir = Keyword.get(parsed, :dir, default_dir())

    if not File.dir?(dir) do
      Mix.shell().error("Directory not found: #{dir}")
      exit({:shutdown, 1})
    end

    serve(port, dir)
  end

  defp default_dir do
    Path.join("_build", "test_lens")
  end

  defp serve(port, dir) do
    Mix.shell().info("Starting TestLens dashboard on http://localhost:#{port} (serving #{dir})")
    Mix.shell().info("Press Ctrl-C to stop.")

    inets_opts = [
      document_root: String.to_charlist(dir),
      port: port,
      server_name: ~c"test_lens_dashboard",
      modules: [:mod_alias, :mod_dir, :mod_get, :mod_head, :mod_log]
    ]

    case :inets.start(:httpd, inets_opts) do
      {:ok, _pid} ->
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Mix.shell().error("Port #{port} already in use.")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Failed to start HTTP server: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
