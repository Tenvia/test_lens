defmodule TestLens.Result do
  @moduledoc "Normalized per-test record."

  @enforce_keys [:test, :status, :time_us, :failures, :tags, :module, :name, :file, :line]
  defstruct [:test, :status, :time_us, :failures, :tags, :module, :name, :file, :line]

  @type t :: %__MODULE__{
          test: ExUnit.Test.t(),
          status: :passed | :failed | :skipped | :excluded | :invalid,
          time_us: non_neg_integer(),
          failures: list(),
          tags: map(),
          module: atom(),
          name: atom(),
          file: binary() | nil,
          line: non_neg_integer() | nil
        }

  @doc """
  Builds a Result from an `ExUnit.Test` struct.

  `test_module` is the most recent `%ExUnit.TestModule{}` received by the
  formatter (via the `{:module_started, _}` event). It is the source of the
  `file` field, because `ExUnit.Test` only stores the test module atom — the
  file path lives on the separate `ExUnit.TestModule` struct. `ExUnit.TestModule`
  has no `line` field, so `line` is always `nil` for v0.1.0.
  """
  @spec new(ExUnit.Test.t(), ExUnit.TestModule.t() | nil) :: t()
  def new(%ExUnit.Test{} = test, test_module \\ nil) do
    status = derive_status(test.state)
    time_us = test.time || 0
    failures = derive_failures(test.state)
    tags = test.tags || %{}

    %__MODULE__{
      test: test,
      status: status,
      time_us: time_us,
      failures: failures,
      tags: tags,
      module: test.module,
      name: test.name,
      file: derive_file(test_module),
      line: nil
    }
  end

  defp derive_status(nil), do: :passed
  defp derive_status({:skipped, _}), do: :skipped
  defp derive_status({:excluded, _}), do: :excluded
  defp derive_status({:failed, _}), do: :failed
  defp derive_status({:invalid, _}), do: :invalid
  defp derive_status(_), do: :passed

  defp derive_failures({:failed, fs}) when is_list(fs), do: fs
  defp derive_failures(_), do: []

  # ExUnit.TestModule carries the :file field. Line numbers are not exposed
  # by ExUnit, so v0.1.0 leaves :line as nil.
  defp derive_file(%ExUnit.TestModule{file: file}) when is_binary(file), do: file
  defp derive_file(_), do: nil

  @doc "True if the test passed."
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: status}), do: status == :passed

  @doc "True if the test failed."
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{status: status}), do: status == :failed

  @doc "True if the test was skipped or excluded."
  @spec skipped?(t()) :: boolean()
  def skipped?(%__MODULE__{status: status}), do: status in [:skipped, :excluded]
end