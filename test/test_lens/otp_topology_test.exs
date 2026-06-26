defmodule TestLens.OTPTopologyTest do
  use ExUnit.Case, async: true

  alias TestLens.OTPTopology

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_topology_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "build/1" do
    test "returns a struct with the expected fields" do
      topology = OTPTopology.build()
      assert %OTPTopology{} = topology
      assert is_list(topology.applications)
      assert is_map(topology.supervisors)
      assert is_list(topology.call_edges)
      assert is_map(topology.module_to_supervisor)
    end

    test "build/1 with nil lib_root produces empty call_edges" do
      topology = OTPTopology.build(nil)
      assert topology.call_edges == []
    end
  end

  describe "call edge AST scan" do
    test "extracts GenServer.call edges from a literal module reference", %{dir: dir} do
      write_file(dir, "billing.ex", """
      defmodule Billing do
        def charge(_amount) do
          GenServer.call(MyApp.Payments, {:charge, 1})
        end
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()

      assert Enum.any?(edges, fn edge ->
               edge.from == Billing and edge.to == MyApp.Payments and edge.kind == :call
             end)
    end

    test "extracts GenServer.cast edges", %{dir: dir} do
      write_file(dir, "broadcaster.ex", """
      defmodule Broadcaster do
        def ping do
          GenServer.cast(MyApp.Worker, :ping)
        end
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()

      assert Enum.any?(edges, fn edge ->
               edge.from == Broadcaster and edge.to == MyApp.Worker and edge.kind == :cast
             end)
    end

    test "extracts Registry.lookup edges with kind :registry_lookup", %{dir: dir} do
      write_file(dir, "repo.ex", """
      defmodule Repo do
        def find(id) do
          Registry.lookup(MyApp.Registry, id)
        end
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()

      assert Enum.any?(edges, fn edge ->
               edge.from == Repo and edge.to == MyApp.Registry and edge.kind == :registry_lookup
             end)
    end

    test "extracts Phoenix.PubSub.broadcast edges", %{dir: dir} do
      write_file(dir, "events.ex", """
      defmodule Events do
        def publish do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "topic", {:hello, 1})
        end
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()

      assert Enum.any?(edges, fn edge ->
               edge.from == Events and edge.to == MyApp.PubSub and edge.kind == :publish
             end)
    end

    test "does not record self-calls", %{dir: dir} do
      write_file(dir, "self.ex", """
      defmodule Self do
        def loop do
          GenServer.call(Self, :tick)
        end
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()

      refute Enum.any?(edges, fn edge -> edge.from == edge.to end)
    end

    test "walks nested directories", %{dir: dir} do
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)

      write_file(sub, "nested.ex", """
      defmodule Nested do
        def call do
          GenServer.call(Other, :ping)
        end
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()

      assert Enum.any?(edges, fn edge -> edge.from == Nested and edge.to == Other end)
    end

    test "returns [] for a non-existent directory" do
      assert OTPTopology.scan_call_edges("/nonexistent/path") |> Enum.to_list() == []
    end

    test "returns [] for files that fail to parse", %{dir: dir} do
      write_file(dir, "broken.ex", "this is not valid elixir ((((")

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()
      assert edges == []
    end

    test "returns [] when lib_root is empty string" do
      assert OTPTopology.scan_call_edges("") |> Enum.to_list() == []
    end

    test "ignores files without .ex extension", %{dir: dir} do
      write_file(dir, "README.md", """
      defmodule Ignored do
        def call, do: GenServer.call(MyApp.X, :y)
      end
      """)

      edges = OTPTopology.scan_call_edges(dir) |> Enum.to_list()
      assert edges == []
    end
  end

  describe "cross_tree_call?/3" do
    test "returns false when both modules are in the same subtree" do
      topology = %OTPTopology{
        module_to_supervisor: %{MyApp.A => :p1, MyApp.B => :p1}
      }

      refute OTPTopology.cross_tree_call?(topology, MyApp.A, MyApp.B)
    end

    test "returns true when modules are in different subtrees" do
      topology = %OTPTopology{
        module_to_supervisor: %{MyApp.A => :p1, MyApp.B => :p2}
      }

      assert OTPTopology.cross_tree_call?(topology, MyApp.A, MyApp.B)
    end

    test "returns false when either module is unmapped" do
      topology = %OTPTopology{
        module_to_supervisor: %{MyApp.A => :p1}
      }

      refute OTPTopology.cross_tree_call?(topology, MyApp.A, MyApp.Unknown)
      refute OTPTopology.cross_tree_call?(topology, MyApp.Unknown, MyApp.A)
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
