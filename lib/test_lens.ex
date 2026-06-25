defmodule TestLens do
  @moduledoc """
  TestLens is a Mix/ExUnit wrapper that improves test output for larger
  Elixir, Phoenix, and OTP codebases. It does not replace ExUnit; it
  registers an additional formatter and augments `mix test` with TestLens
  flags via the `mix test.lens` task.
  """

  @version "2.0.0"

  @spec version() :: String.t()
  def version, do: @version
end
