defmodule TestLens.DashboardTest do
  use ExUnit.Case, async: true

  alias TestLens.Dashboard

  setup do
    dir =
      Path.join(System.tmp_dir!(), "test_lens_dashboard_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "default_dir/0" do
    test "returns _build/test_lens/dashboard" do
      assert Dashboard.default_dir() == "_build/test_lens/dashboard"
    end
  end

  describe "generate/1" do
    test "creates the three dashboard files", %{dir: dir} do
      assert :ok = Dashboard.generate(dir)
      assert File.exists?(Path.join(dir, "index.html"))
      assert File.exists?(Path.join(dir, "app.js"))
      assert File.exists?(Path.join(dir, "app.css"))
    end

    test "creates parent directories that do not exist", %{dir: dir} do
      nested = Path.join([dir, "deep", "nested"])
      assert :ok = Dashboard.generate(nested)
      assert File.exists?(Path.join(nested, "index.html"))
    end

    test "index.html contains the navigation tabs" do
      assert :ok = Dashboard.generate()
      content = File.read!(Path.join(Dashboard.default_dir(), "index.html"))
      assert content =~ ~s(data-tab="summary")
      assert content =~ ~s(data-tab="failures")
      assert content =~ ~s(data-tab="repair")
      assert content =~ ~s(data-tab="otp")
      assert content =~ ~s(data-tab="arch")
    end

    test "index.html is self-contained (no external CDN resources)" do
      assert :ok = Dashboard.generate()
      content = File.read!(Path.join(Dashboard.default_dir(), "index.html"))
      # Local links to the bundled app.css/app.js are intentional.
      # We only assert that no CDN / external resources are referenced.
      refute content =~ "https://"
      refute content =~ "http://"
      refute content =~ "<img"
    end

    test "app.css defines severity classes" do
      assert :ok = Dashboard.generate()
      content = File.read!(Path.join(Dashboard.default_dir(), "app.css"))
      assert content =~ ".severity-critical"
      assert content =~ ".severity-warn"
      assert content =~ ".severity-info"
    end

    test "app.js wires tab switching and fetch" do
      assert :ok = Dashboard.generate()
      content = File.read!(Path.join(Dashboard.default_dir(), "app.js"))
      assert content =~ "switchTab"
      assert content =~ "fetchJSON"
      assert content =~ "renderSummary"
    end

    test "app.js includes all five tabs as renderers" do
      assert :ok = Dashboard.generate()
      content = File.read!(Path.join(Dashboard.default_dir(), "app.js"))

      # Tab names map to render functions: summary → renderSummary,
      # otp → renderOTP, etc. Match the function definition by tab
      # name (case-insensitive) and the dynamic dispatcher.
      expected_renderers = %{
        "summary" => "renderSummary",
        "failures" => "renderFailures",
        "repair" => "renderRepair",
        "otp" => "renderOTP",
        "arch" => "renderArch"
      }

      for {tab, renderer} <- expected_renderers do
        assert content =~ "#{tab}: #{renderer}", "missing renderer #{renderer} for tab #{tab}"
      end

      assert content =~ "renderers[state.activeTab]", "missing renderers[] dispatcher"
    end
  end
end
