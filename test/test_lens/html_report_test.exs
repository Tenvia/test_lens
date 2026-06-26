defmodule TestLens.HTMLReportTest do
  use ExUnit.Case, async: true

  alias TestLens.{HTMLReport, Result}

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_html_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp passed_result do
    %Result{
      test: %ExUnit.Test{
        name: :"test ok",
        module: SomeMod,
        state: nil,
        time: 100,
        tags: %{},
        logs: []
      },
      status: :passed,
      time_us: 100,
      failures: [],
      tags: %{},
      module: SomeMod,
      name: :"test ok",
      file: "test/x_test.exs",
      line: nil
    }
  end

  defp failed_result do
    %Result{
      test: %ExUnit.Test{
        name: :"test boom",
        module: SomeMod,
        state: {:failed, []},
        time: 200,
        tags: %{},
        logs: []
      },
      status: :failed,
      time_us: 200,
      failures: [{:error, %RuntimeError{message: "boom"}, []}],
      tags: %{},
      module: SomeMod,
      name: :"test boom",
      file: "test/x_test.exs",
      line: nil
    }
  end

  # Exit failures get classified as :critical by the Classifier
  defp critical_failed_result do
    %Result{
      test: %ExUnit.Test{
        name: :"test exits",
        module: CritMod,
        state: {:failed, []},
        time: 200,
        tags: %{},
        logs: []
      },
      status: :failed,
      time_us: 200,
      failures: [{:exit, :timeout, []}],
      tags: %{},
      module: CritMod,
      name: :"test exits",
      file: "test/crit_test.exs",
      line: nil
    }
  end

  # --- default path -------------------------------------------------------

  test "default_path/0 returns the conventional _build/test_lens path" do
    assert HTMLReport.default_path() == "_build/test_lens/report.html"
  end

  # --- build/3 shape ------------------------------------------------------

  test "build/3 returns a string starting with the DOCTYPE" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert is_binary(html)
    assert String.starts_with?(html, "<!DOCTYPE html>")
  end

  test "build/3 contains all required section anchors" do
    html = HTMLReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)

    for id <- [
          "summary",
          "failures-by-area",
          "failures-by-type",
          "slow-tests",
          "suggested-reruns",
          "raw-failure-details"
        ] do
      assert html =~ ~s(id="#{id}"), "missing section: #{id}"
    end
  end

  test "build/3 with a failure renders a critical-failures section when severity is critical" do
    html = HTMLReport.build([critical_failed_result()], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ ~s(id="critical-failures")
  end

  test "build/3 with no results renders the summary section" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "0 passed"
    assert html =~ "0 failed"
  end

  test "build/3 with a failure renders the raw failure body" do
    html = HTMLReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
    # from the RuntimeError message
    assert html =~ "boom"
  end

  test "build/3 with failures groups them by type" do
    html = HTMLReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "id=\"failures-by-type\""
  end

  test "build/3 with failures groups them by area" do
    html = HTMLReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "id=\"failures-by-area\""
  end

  test "build/3 includes the suggested --stale rerun" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "mix test.lens -- --stale"
  end

  test "build/3 with failures includes the --failed rerun" do
    html = HTMLReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "mix test.lens -- --failed"
  end

  test "build/3 has no external resources" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    # Links to external URLs are allowed (e.g. footer project link).
    # But external stylesheets, scripts, and web fonts are not.
    refute html =~ ~s(<link rel="stylesheet"),
           "should not include external stylesheets"

    refute html =~ ~s(<script),
           "should not include script tags"

    refute html =~ ~s(@import),
           "should not include @import for external CSS"

    refute html =~ ~s(url(http),
           "should not include url() with http for web fonts/images"
  end

  test "build/3 has no script tags (no JavaScript)" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    refute html =~ ~s(<script)
  end

  test "build/3 uses semantic HTML5 elements" do
    html = HTMLReport.build([failed_result()], %{run: 0, async: nil, load: nil}, nil)

    for tag <- ["<header", "<section", "<footer", "<details", "<summary"] do
      assert html =~ tag, "expected semantic tag: #{tag}"
    end
  end

  test "build/3 includes the TestLens version" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "TestLens #{TestLens.version()}"
  end

  test "build/3 has inline CSS (not a stylesheet link)" do
    html = HTMLReport.build([], %{run: 0, async: nil, load: nil}, nil)
    assert html =~ "<style>"
    refute html =~ ~s(<link rel="stylesheet")
  end

  # --- write/4 -----------------------------------------------------------

  test "write/4 creates the HTML report at the given path", %{dir: dir} do
    path = Path.join(dir, "report.html")
    assert :ok = HTMLReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
    assert File.exists?(path)
  end

  test "write/4 creates parent directories that do not exist", %{dir: dir} do
    path = Path.join([dir, "deep", "nested", "report.html"])
    assert :ok = HTMLReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
    assert File.exists?(path)
  end

  test "write/4 the file content is a complete HTML document", %{dir: dir} do
    path = Path.join(dir, "report.html")

    :ok =
      HTMLReport.write(
        path,
        [passed_result(), failed_result()],
        %{run: 0, async: nil, load: nil},
        7
      )

    content = File.read!(path)
    assert String.starts_with?(content, "<!DOCTYPE html>")
    assert String.ends_with?(content, "</html>\n")
  end

  test "write/4 overwrites an existing file", %{dir: dir} do
    path = Path.join(dir, "report.html")
    File.write!(path, "garbage")
    :ok = HTMLReport.write(path, [], %{run: 0, async: nil, load: nil}, nil)
    content = File.read!(path)
    refute content =~ "garbage"
  end
end
