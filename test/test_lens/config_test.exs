defmodule TestLens.ConfigTest do
  use ExUnit.Case, async: true

  alias TestLens.Config

  test "defaults/0 produces :tty format with color and no json" do
    c = Config.defaults()
    assert c.format == :tty
    assert c.color == true
    assert c.json == false
    assert c.output == :stdout
    assert c.impact == false
    assert c.rerun == false
    assert c.extras == []
  end

  test "from_option_parser/1 with json:true forces json true" do
    c = Config.from_option_parser(json: true)
    assert c.json == true
    # normalize forces format to :json
    assert c.format == :json
  end

  test "from_option_parser/1 with no_color:true forces color false" do
    c = Config.from_option_parser(no_color: true)
    assert c.color == false
  end

  test "from_option_parser/1 with color:true forces color true" do
    c = Config.from_option_parser(color: true)
    assert c.color == true
  end

  test "from_option_parser/1 with empty opts yields defaults" do
    c = Config.from_option_parser([])
    assert c == Config.defaults()
  end

  test "normalize/1 forces format: :json when json: true" do
    c = %Config{json: true, format: :tty}
    n = Config.normalize(c)
    assert n.format == :json
  end

  test "normalize/1 leaves format alone when json: false" do
    c = %Config{json: false, format: :tty}
    n = Config.normalize(c)
    assert n.format == :tty
  end

  test "from_option_parser/1 with json_file sets the json_file field" do
    c = Config.from_option_parser(json_file: "tmp/x.json")
    assert c.json_file == "tmp/x.json"
  end

  test "from_option_parser/1 without json_file defaults to nil" do
    c = Config.from_option_parser([])
    assert c.json_file == nil
  end

  test "from_option_parser/1 with html_file sets the html_file field" do
    c = Config.from_option_parser(html_file: "tmp/x.html")
    assert c.html_file == "tmp/x.html"
  end

  test "from_option_parser/1 without html_file defaults to nil" do
    c = Config.from_option_parser([])
    assert c.html_file == nil
  end
end
