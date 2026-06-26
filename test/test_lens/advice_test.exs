defmodule TestLens.AdviceTest do
  use ExUnit.Case, async: true

  alias TestLens.Advice
  alias TestLens.Architecture.Finding
  alias TestLens.OTPTopology

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_advice_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "schema_version/0" do
    test "returns 4.0" do
      assert Advice.schema_version() == "4.0"
    end
  end

  describe "default_path/0" do
    test "returns the conventional _build/test_lens path" do
      assert Advice.default_path() == "_build/test_lens/advice.json"
    end
  end

  describe "build/2" do
    test "produces an artifact with the canonical top-level keys" do
      artifact = Advice.build(%OTPTopology{})

      for key <- [
            "schema_version",
            "test_lens_version",
            "project",
            "run",
            "totals",
            "findings",
            "safety"
          ] do
        assert Map.has_key?(artifact, key), "missing key: #{key}"
      end
    end

    test "totals reflect the findings list", %{dir: dir} do
      write_file(dir, "raw_spawn.ex", """
      defmodule RawSpawn do
        def start, do: :erlang.spawn(fn -> :ok end)
      end
      """)

      topology =
        %OTPTopology{
          call_edges: [%{from: Billing, to: Other, kind: :call}],
          module_to_supervisor: %{Billing => :p1, Other => :p2}
        }

      artifact = Advice.build(topology, dir)

      # CrossTreeCall rule fires for Billing->Other across subtrees.
      # RawProcessSpawn rule fires for RawSpawn.
      assert artifact["totals"]["total"] >= 1
      assert is_integer(artifact["totals"]["warn"])
      assert is_integer(artifact["totals"]["info"])
    end

    test "finds cross-tree-call when caller and callee are in different subtrees", %{dir: dir} do
      write_file(dir, "billing.ex", """
      defmodule Billing do
        def charge(_), do: GenServer.call(Other, :ping)
      end
      """)

      topology =
        %OTPTopology{
          call_edges: [%{from: Billing, to: Other, kind: :call}],
          module_to_supervisor: %{Billing => :p1, Other => :p2}
        }

      artifact = Advice.build(topology, dir)
      assert Enum.any?(artifact["findings"], fn f -> f["rule_id"] == "cross_tree_call" end)
    end

    test "findings are JSON-encodable maps" do
      artifact = Advice.build(%OTPTopology{})
      encoded = Jason.encode!(artifact)
      assert is_binary(encoded)
      assert String.contains?(encoded, "\"schema_version\":\"4.0\"")
    end

    test "safety block declares excluded fields" do
      artifact = Advice.build(%OTPTopology{})
      assert "env" in artifact["safety"]["excluded_fields"]
      assert "application_config" in artifact["safety"]["excluded_fields"]
    end
  end

  describe "encode/1 + write/3" do
    test "encode/1 returns valid JSON" do
      artifact = Advice.build(%OTPTopology{})
      encoded = Advice.encode(artifact)
      assert String.starts_with?(encoded, "{")
      assert String.ends_with?(encoded, "}")
    end

    test "write/3 creates the artifact file at the given path", %{dir: dir} do
      path = Path.join(dir, "advice.json")
      assert :ok = Advice.write(path, %OTPTopology{})
      assert File.exists?(path)
    end

    test "write/3 creates parent directories that do not exist", %{dir: dir} do
      path = Path.join([dir, "deep", "nested", "advice.json"])
      assert :ok = Advice.write(path, %OTPTopology{})
      assert File.exists?(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end
end
