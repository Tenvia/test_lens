defmodule TestLens.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias TestLens.ProjectConfig

  setup do
    dir = Path.join(System.tmp_dir!(), "test_lens_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ---------------------------------------------------------------------------
  # load/1 — no config file
  # ---------------------------------------------------------------------------

  test "load/1 returns an empty config when the file does not exist" do
    assert {:ok, %ProjectConfig{project: nil, areas: %{}, critical_tags: []}} =
             ProjectConfig.load("/no/such/file.exs")
  end

  test "load_or_default/1 returns an empty config for a missing file" do
    assert %ProjectConfig{project: nil, areas: %{}, critical_tags: []} =
             ProjectConfig.load_or_default("/no/such/file.exs")
  end

  # ---------------------------------------------------------------------------
  # load/1 — valid config
  # ---------------------------------------------------------------------------

  test "load/1 parses a well-formed config", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")

    # Use tuples inside lists to avoid keyword list parsing issues with string keys.
    # This is valid Elixir: [key: value] is keyword syntax, but value can be any term,
    # including a list of tuples like [{"path", [...]}].
    File.write!(path, """
    [
      project: "ExampleApp",
      areas: [
        {"test/example_app/accounts", [label: "Accounts", impact: :high, user_facing: true]}
      ],
      critical_tags: [:payment, :security]
    ]
    """)

    assert {:ok, %ProjectConfig{project: "ExampleApp"}} = ProjectConfig.load(path)
    assert {:ok, %ProjectConfig{critical_tags: [:payment, :security]}} = ProjectConfig.load(path)

    assert {:ok, %ProjectConfig{areas: %{"test/example_app/accounts" => a}}} =
             ProjectConfig.load(path)

    assert a.label == "Accounts"
    assert a.impact == :high
    assert a.user_facing == true
  end

  test "load/1 with only some keys uses defaults for the rest", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, "[project: \"X\"]")

    assert {:ok, %ProjectConfig{project: "X", areas: %{}, critical_tags: []}} =
             ProjectConfig.load(path)
  end

  test "load/1 parses all impact levels correctly", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")

    File.write!(path, """
    [
      areas: [
        {"test/high",     [label: "High",     impact: :high,   user_facing: true]},
        {"test/medium",   [label: "Medium",   impact: :medium, user_facing: false]},
        {"test/low",      [label: "Low",      impact: :low,    user_facing: true]},
        {"test/none",     [label: "None",     impact: :none,   user_facing: false]},
        {"test/defaults",  [label: "Defaults"]}
      ]
    ]
    """)

    assert {:ok, %ProjectConfig{areas: areas}} = ProjectConfig.load(path)
    assert areas["test/high"].impact == :high
    assert areas["test/medium"].impact == :medium
    assert areas["test/low"].impact == :low
    assert areas["test/none"].impact == :none
    # Missing impact key defaults to :none
    assert areas["test/defaults"].impact == :none
    # Missing user_facing key defaults to false
    assert areas["test/defaults"].user_facing == false
  end

  test "load/1 parses multiple areas", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")

    File.write!(path, """
    [
      project: "MultiAreaApp",
      areas: [
        {"test/app/accounts",  [label: "Accounts",  impact: :high, user_facing: true]},
        {"test/app/billing",   [label: "Billing",   impact: :high, user_facing: true]},
        {"test/app/workers",   [label: "Workers",   impact: :medium, user_facing: false]},
        {"test/app/support",   [label: "Support",   impact: :low, user_facing: true]}
      ],
      critical_tags: [:payment, :security, :data_integrity]
    ]
    """)

    assert {:ok, config} = ProjectConfig.load(path)
    assert map_size(config.areas) == 4
    assert config.critical_tags == [:payment, :security, :data_integrity]
  end

  # ---------------------------------------------------------------------------
  # from_keyword/1 — valid input
  # ---------------------------------------------------------------------------

  test "from_keyword/1 normalises a raw keyword list" do
    assert {:ok, %ProjectConfig{project: "App", areas: %{}, critical_tags: []}} =
             ProjectConfig.from_keyword(project: "App")
  end

  test "from_keyword/1 normalises areas from a keyword list" do
    # Use explicit tuple syntax {"path", [...]} to avoid keyword list parsing issues
    raw = [areas: [{"test/accounts", [label: "Accounts", impact: :high, user_facing: true]}]]

    assert {:ok, %ProjectConfig{areas: areas}} = ProjectConfig.from_keyword(raw)
    assert areas["test/accounts"].label == "Accounts"
    assert areas["test/accounts"].impact == :high
    assert areas["test/accounts"].user_facing == true
  end

  test "from_keyword/1 falls back to :none for an invalid impact" do
    raw = [areas: [{"test/x", [label: "X", impact: :invalid_value]}]]
    assert {:ok, %ProjectConfig{areas: %{"test/x" => %{impact: :none}}}} = ProjectConfig.from_keyword(raw)
  end

  test "from_keyword/1 ignores area entries that are not {string, list}" do
    raw = [
      areas: [
        {"test/valid", [label: "Valid", impact: :high]},
        {123, [label: "NotAString"]},
        {"test/no_list", "not a keyword list"},
        {"test/nil_area", nil},
        {["nested"], [label: "ListAsKey"]},
        {nil, [label: "NilKey"]}
      ]
    ]

    assert {:ok, %ProjectConfig{areas: areas}} = ProjectConfig.from_keyword(raw)
    assert Map.has_key?(areas, "test/valid")
    refute Map.has_key?(areas, "test/no_list")
    refute Map.has_key?(areas, "test/nil_area")
    assert map_size(areas) == 1
  end

  test "from_keyword/1 filters critical_tags down to atoms only" do
    raw = [critical_tags: [:atom, "string", 123, nil, :another_atom, :last]]
    assert {:ok, %ProjectConfig{critical_tags: [:atom, :another_atom, :last]}} = ProjectConfig.from_keyword(raw)
  end

  test "from_keyword/1 accepts empty keyword lists for all fields" do
    assert {:ok, %ProjectConfig{project: nil, areas: %{}, critical_tags: []}} =
             ProjectConfig.from_keyword([])
  end

  test "from_keyword/1 ignores unknown top-level keys" do
    raw = [project: "App", unknown_key: "ignored", another: 123, areas: []]
    assert {:ok, config} = ProjectConfig.from_keyword(raw)
    assert config.project == "App"
  end

  test "from_keyword/1 handles area with only label and defaults for impact and user_facing" do
    raw = [areas: [{"test/x", [label: "Only Label"]}]]
    assert {:ok, %ProjectConfig{areas: %{"test/x" => %{impact: :none, user_facing: false}}}} = ProjectConfig.from_keyword(raw)
  end

  test "from_keyword/1 converts non-string label to string" do
    raw = [areas: [{"test/x", [label: :atom_label]}]]
    assert {:ok, %ProjectConfig{areas: %{"test/x" => %{label: "atom_label"}}}} = ProjectConfig.from_keyword(raw)
  end

  test "from_keyword/1 falls back to Unnamed when label is nil" do
    raw = [areas: [{"test/x", [impact: :high]}]]
    assert {:ok, %ProjectConfig{areas: %{"test/x" => %{label: "Unnamed"}}}} = ProjectConfig.from_keyword(raw)
  end

  # ---------------------------------------------------------------------------
  # from_keyword/1 — invalid input
  # ---------------------------------------------------------------------------

  test "from_keyword/1 returns an error when the config is not a keyword list" do
    assert {:error, msg} = ProjectConfig.from_keyword(%{not: "a keyword list"})
    assert msg =~ "keyword list"
    assert msg =~ "%{not:"
  end

  test "from_keyword/1 returns an error for a non-list non-map (atom)" do
    assert {:error, msg} = ProjectConfig.from_keyword(:atom)
    assert msg =~ "keyword list"
  end

  test "from_keyword/1 returns an error for a non-list non-map (integer)" do
    assert {:error, msg} = ProjectConfig.from_keyword(123)
    assert msg =~ "keyword list"
  end

  test "from_keyword/1 returns an error for a non-list non-map (string)" do
    assert {:error, msg} = ProjectConfig.from_keyword("not a list")
    assert msg =~ "keyword list"
  end

  # ---------------------------------------------------------------------------
  # load/1 — invalid config file
  # ---------------------------------------------------------------------------

  test "load/1 returns an error for invalid Elixir syntax", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, "this is not elixir [unclosed")
    assert {:error, msg} = ProjectConfig.load(path)
    assert msg =~ "Invalid Elixir syntax"
  end

  test "load/1 returns an error when the file raises on evaluation", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, ~s|raise "boom"|)
    assert {:error, msg} = ProjectConfig.load(path)
    assert msg =~ "boom"
  end

  test "load/1 returns an error when the file evaluates to a non-list", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, ~s|"a string"|)
    assert {:error, msg} = ProjectConfig.load(path)
    assert msg =~ "keyword list"
  end

  test "load/1 returns an error when the file evaluates to a map", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, "%{a: 1}")
    assert {:error, msg} = ProjectConfig.load(path)
    assert msg =~ "keyword list"
  end

  # ---------------------------------------------------------------------------
  # load_or_default/1 — safety guarantees
  # ---------------------------------------------------------------------------

  test "load_or_default/1 logs a warning and returns an empty config for invalid config", %{
    dir: dir
  } do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, "this is not elixir [")

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        config = ProjectConfig.load_or_default(path)
        assert config == %ProjectConfig{project: nil, areas: %{}, critical_tags: []}
      end)

    assert output =~ "[TestLens]"
    assert output =~ path
  end

  test "load_or_default/1 returns empty config and warns when file evaluates to non-list", %{
    dir: dir
  } do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, ~s|"not a list"|)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        config = ProjectConfig.load_or_default(path)
        assert config == %ProjectConfig{project: nil, areas: %{}, critical_tags: []}
      end)

    assert output =~ "[TestLens]"
  end

  test "load_or_default/1 returns empty config and warns when file raises", %{dir: dir} do
    path = Path.join(dir, ".test_lens.exs")
    File.write!(path, ~s|raise "load error"|)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        config = ProjectConfig.load_or_default(path)
        assert config == %ProjectConfig{project: nil, areas: %{}, critical_tags: []}
      end)

    assert output =~ "[TestLens]"
    assert output =~ "load error"
  end

  # ---------------------------------------------------------------------------
  # struct shape
  # ---------------------------------------------------------------------------

  test "the struct has the expected fields" do
    config = %ProjectConfig{}
    assert Map.has_key?(config, :project)
    assert Map.has_key?(config, :areas)
    assert Map.has_key?(config, :critical_tags)
  end
end
