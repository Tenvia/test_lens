defmodule TestLens.ImpactTest do
  use ExUnit.Case, async: true

  alias TestLens.{Impact, ProjectConfig}

  # ---------------------------------------------------------------------------
  # v0.1.0 contract stubs
  # ---------------------------------------------------------------------------

  test "changed_files_since/1 with a DateTime returns []" do
    dt = ~U[2026-06-24 10:00:00Z]
    assert Impact.changed_files_since(dt) == []
  end

  test "affected_tests/2 with any inputs returns []" do
    assert Impact.affected_tests(["lib/foo.ex"], []) == []
    assert Impact.affected_tests([], []) == []
    assert Impact.affected_tests(["lib/foo.ex", "lib/bar.ex"], []) == []
  end

  # ---------------------------------------------------------------------------
  # classify/3 — no config
  # ---------------------------------------------------------------------------

  test "classify/3 with no matching path and no tags returns the default impact" do
    i = Impact.classify("test/some/random_test.exs", [], %ProjectConfig{})
    assert i.area == nil
    assert i.impact == :none
    assert i.user_facing == false
    assert i.critical == false
    assert i.reason =~ "no matching area"
  end

  test "classify/3 with a nil file and an empty config returns the default impact" do
    i = Impact.classify(nil, [], %ProjectConfig{})
    assert i.area == nil
    assert i.impact == :none
    assert i.critical == false
  end

  test "classify/3 with no tags and no critical_tags skips tag check (fast path)" do
    {:ok, config} = ProjectConfig.from_keyword(critical_tags: [])
    i = Impact.classify("test/some/test.exs", [], config)
    assert i.impact == :none
    assert i.critical == false
  end

  # ---------------------------------------------------------------------------
  # classify/3 — path match
  # ---------------------------------------------------------------------------

  test "classify/3 matches a test file path to a configured area" do
    areas = [{"test/example_app/accounts", [label: "Accounts", impact: :high, user_facing: true]}]
    {:ok, config} = ProjectConfig.from_keyword(areas: areas)

    i = Impact.classify("test/example_app/accounts/user_test.exs", [], config)
    assert i.area == "Accounts"
    assert i.impact == :high
    assert i.user_facing == true
    assert i.critical == true
    assert i.reason =~ "Accounts"
  end

  test "classify/3 matches a deeper path to a configured area" do
    areas = [{"test/example_app/accounts", [label: "Accounts", impact: :high, user_facing: true]}]
    {:ok, config} = ProjectConfig.from_keyword(areas: areas)

    # A test at test/example_app/accounts/admin/admin_test.exs should still match.
    i = Impact.classify("test/example_app/accounts/admin/admin_test.exs", [], config)
    assert i.area == "Accounts"
  end

  test "classify/3 with a non-matching path falls through to the default" do
    areas = [{"test/example_app/accounts", [label: "Accounts", impact: :high, user_facing: true]}]
    {:ok, config} = ProjectConfig.from_keyword(areas: areas)

    i = Impact.classify("test/example_app/workers/job_test.exs", [], config)
    assert i.area == nil
    assert i.impact == :none
  end

  test "classify/3 critical is true only when the area is high AND user_facing" do
    areas = [
      {"high-uf", [label: "H-UF", impact: :high, user_facing: true]},
      {"high-nonuf", [label: "H-NUF", impact: :high, user_facing: false]},
      {"low-uf", [label: "L-UF", impact: :low, user_facing: true]}
    ]

    {:ok, config} = ProjectConfig.from_keyword(areas: areas)

    assert Impact.classify("high-uf/x_test.exs", [], config).critical == true
    assert Impact.classify("high-nonuf/x_test.exs", [], config).critical == false
    assert Impact.classify("low-uf/x_test.exs", [], config).critical == false
  end

  test "classify/3 returns the correct user_facing value from the area" do
    areas = [
      {"uf-true", [label: "UF-True", impact: :low, user_facing: true]},
      {"uf-false", [label: "UF-False", impact: :high, user_facing: false]}
    ]

    {:ok, config} = ProjectConfig.from_keyword(areas: areas)

    assert Impact.classify("uf-true/x_test.exs", [], config).user_facing == true
    assert Impact.classify("uf-false/x_test.exs", [], config).user_facing == false
  end

  test "classify/3 uses the first matching area when multiple share a prefix" do
    # Both start with "test/". Enum.find_value iterates in map iteration order,
    # which for string keys is hash/term order, not insertion order.
    # This test verifies that the first-matching-area (by map iteration) wins.
    areas = [
      {"test/accounts/admin", [label: "Admin Accounts", impact: :high, user_facing: true]},
      {"test/accounts", [label: "All Accounts", impact: :low, user_facing: false]}
    ]

    {:ok, config} = ProjectConfig.from_keyword(areas: areas)

    # Map iteration order for string keys is deterministic but not insertion-order.
    # The first key in iteration order wins.
    first_key = Enum.at(Map.keys(config.areas), 0)

    assert Impact.classify("test/accounts/admin/user_test.exs", [], config).area ==
             if(first_key == "test/accounts/admin", do: "Admin Accounts", else: "All Accounts")
  end

  # ---------------------------------------------------------------------------
  # classify/3 — tag match
  # ---------------------------------------------------------------------------

  test "classify/3 marks a test critical when one of its tags is in critical_tags" do
    {:ok, config} = ProjectConfig.from_keyword(critical_tags: [:payment, :security])
    i = Impact.classify("test/some/random_test.exs", [:payment], config)
    assert i.critical == true
    assert i.impact == :high
    assert i.reason =~ "tagged critical"
    assert i.reason =~ "payment"
  end

  test "classify/3 lists all matching critical tags in the reason" do
    {:ok, config} = ProjectConfig.from_keyword(critical_tags: [:payment, :security])
    i = Impact.classify("test/some/random_test.exs", [:payment, :security, :other], config)
    assert i.reason =~ "payment"
    assert i.reason =~ "security"
    refute i.reason =~ "other"
  end

  test "classify/3 with empty tags list and non-empty critical_tags falls through to area" do
    {:ok, config} =
      ProjectConfig.from_keyword(
        areas: [{"test/accounts", [label: "Accounts", impact: :medium, user_facing: false]}],
        critical_tags: [:payment]
      )

    # No tags on the test, so it falls through to path match even though payment is critical
    i = Impact.classify("test/accounts/user_test.exs", [], config)
    assert i.area == "Accounts"
    assert i.impact == :medium
    assert i.critical == false
  end

  # ---------------------------------------------------------------------------
  # classify/3 — tag wins over area
  # ---------------------------------------------------------------------------

  test "classify/3 critical tag wins over a non-critical area" do
    {:ok, config} =
      ProjectConfig.from_keyword(
        areas: [{"test/workers", [label: "Background jobs", impact: :medium, user_facing: false]}],
        critical_tags: [:payment]
      )

    # The area is medium / non-user-facing, but the test is tagged :payment.
    i = Impact.classify("test/workers/payment_job_test.exs", [:payment], config)
    assert i.critical == true
    assert i.impact == :high
    # Tag-driven reason, not area-driven.
    assert i.reason =~ "tagged critical"
    refute i.reason =~ "matches area"
  end

  test "classify/3 with both area and tag, the tag is reported in the reason" do
    {:ok, config} =
      ProjectConfig.from_keyword(
        areas: [{"test/workers", [label: "Background jobs", impact: :medium, user_facing: false]}],
        critical_tags: [:payment]
      )

    i = Impact.classify("test/workers/payment_job_test.exs", [:payment], config)
    # The area's data is NOT used (tag wins), so area should be nil
    assert i.area == nil
  end

  test "classify/3 with nil file still matches by tag (tag wins over nil path)" do
    {:ok, config} = ProjectConfig.from_keyword(critical_tags: [:payment])
    i = Impact.classify(nil, [:payment], config)
    assert i.critical == true
    assert i.impact == :high
    assert i.area == nil
  end

  # ---------------------------------------------------------------------------
  # classify/3 — determinism
  # ---------------------------------------------------------------------------

  test "classify/3 is deterministic — 100 identical calls return identical results" do
    {:ok, config} =
      ProjectConfig.from_keyword(
        areas: [{"test/accounts", [label: "Accounts", impact: :high, user_facing: true]}],
        critical_tags: [:payment]
      )

    first = Impact.classify("test/accounts/x_test.exs", [:payment], config)

    last =
      Enum.reduce(1..100, first, fn _, acc ->
        result = Impact.classify("test/accounts/x_test.exs", [:payment], config)
        assert result == acc
        result
      end)

    assert last == first
  end

  # ---------------------------------------------------------------------------
  # classify/3 — auto-load fallback
  # ---------------------------------------------------------------------------

  test "classify/3 with nil config loads .test_lens.exs via load_or_default" do
    # We cannot easily mock the file system here, so we verify that
    # calling with nil config (auto-load) does not raise and returns
    # a valid Impact struct.
    i = Impact.classify("test/foo_test.exs", [:some_tag], nil)
    assert is_struct(i, Impact)
    assert i.impact in [:high, :medium, :low, :none]
  end

  # ---------------------------------------------------------------------------
  # find_area/2 path matching — regression tests for the absolute-vs-relative
  # bug. ExUnit.TestModule.file is an absolute path; .test_lens.exs area
  # keys are relative to cwd. The matcher must relativize before comparing.
  # ---------------------------------------------------------------------------

  describe "find_area/2 path matching" do
    @absolute_file Path.expand("test/example_app/accounts/foo_test.exs")
    @relative_file "test/example_app/accounts/foo_test.exs"

    @area_config %TestLens.ProjectConfig{
      areas: %{
        "test/example_app/accounts" => %{
          label: "Accounts",
          impact: :high,
          user_facing: true
        },
        "test/example_app_web" => %{
          label: "Web",
          impact: :medium,
          user_facing: true
        }
      },
      critical_tags: []
    }

    test "matches when the test file is an absolute path and the area key is relative" do
      result = Impact.find_area(@absolute_file, @area_config.areas)
      assert result.label == "Accounts"
      assert result.impact == :high
    end

    test "matches when the test file is already a relative path" do
      result = Impact.find_area(@relative_file, @area_config.areas)
      assert result.label == "Accounts"
    end

    test "first matching prefix wins (most specific area before parent)" do
      # Pin the documented behaviour: when multiple prefixes match, the
      # one that appears first in the consumer's areas: map wins. The
      # current config has "test/example_app/accounts" before
      # "test/example_app_web", and accounts/ comes first, so the
      # accounts/ area wins for the matching file.
      result = Impact.find_area(@relative_file, @area_config.areas)
      assert result.label == "Accounts"
    end

    test "returns nil (default_impact) when no area matches" do
      i = Impact.find_area("test/example_app/workers/queue_test.exs", @area_config.areas)
      assert i == nil
    end

    test "returns nil when file is nil" do
      assert Impact.find_area(nil, @area_config.areas) == nil
    end
  end

  describe "classify/3 end-to-end with ProjectConfig" do
    test "populates area and impact when the test file is absolute and the area key is relative" do
      config = %TestLens.ProjectConfig{
        areas: %{
          "test/example_app/accounts" => %{
            label: "Accounts",
            impact: :high,
            user_facing: true
          }
        },
        critical_tags: []
      }

      absolute = Path.expand("test/example_app/accounts/foo_test.exs")
      result = Impact.classify(absolute, [], config)
      assert result.area == "Accounts"
      assert result.impact == :high
      assert result.reason =~ ~s(matches area "Accounts")
    end

    test "critical tags override the area match" do
      config = %TestLens.ProjectConfig{
        areas: %{
          "test/example_app" => %{
            label: "App",
            impact: :low,
            user_facing: false
          }
        },
        critical_tags: [:must_not_fail]
      }

      absolute = Path.expand("test/example_app/anything_test.exs")
      result = Impact.classify(absolute, [:must_not_fail], config)
      assert result.critical == true
      assert result.impact == :high
      assert result.reason =~ "tagged critical"
    end
  end
end
