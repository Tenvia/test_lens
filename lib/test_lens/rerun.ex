defmodule TestLens.Rerun do
  @moduledoc "Builds the suggested `--failed` rerun command."

  @spec failed_test_args([TestLens.Result.t()]) :: [String.t()]
  def failed_test_args(results) do
    if Enum.any?(results, &TestLens.Result.failed?/1) do
      ["--failed"]
    else
      []
    end
  end

  @spec rerun_command([TestLens.Result.t()]) :: String.t()
  def rerun_command(results) do
    "mix test.lens -- " <> Enum.join(failed_test_args(results), " ")
  end
end