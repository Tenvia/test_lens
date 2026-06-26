defmodule Mix.Tasks.Lens.ServeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_serve_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "run/1 in non-dev env" do
    @tag :skip
    test "refuses to start when MIX_ENV is not :dev", %{dir: dir} do
      capture_log(fn ->
        assert catch_exit(Mix.Tasks.Lens.Serve.run(["--port", "55555", "--dir", dir])) ==
                 {:shutdown, 1}
      end)
    end
  end
end
