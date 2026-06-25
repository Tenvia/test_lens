defmodule TestLens.FingerprintTest do
  use ExUnit.Case, async: true

  alias TestLens.Fingerprint

  test "compute/1 returns a 64-char lowercase hex SHA-256" do
    fp =
      Fingerprint.compute(%{
        kind: :error,
        classification_type: :function_clause,
        file: "test/foo_test.exs",
        top_app_frame: "MyApp.Foo.bar/1"
      })

    assert is_binary(fp)
    assert byte_size(fp) == 64
    assert fp == String.downcase(fp)
    assert Regex.match?(~r/^[0-9a-f]+$/, fp)
  end

  test "compute/1 is deterministic for identical inputs" do
    input = %{
      kind: :exit,
      classification_type: :timeout,
      file: "test/x_test.exs",
      top_app_frame: "MyApp.X.run/0"
    }

    assert Fingerprint.compute(input) == Fingerprint.compute(input)
  end

  test "compute/1 differs when kind changes" do
    base = %{kind: :error, classification_type: :assertion, file: "f.exs", top_app_frame: "M.f/1"}

    a = Fingerprint.compute(base)
    b = Fingerprint.compute(%{base | kind: :exit})

    refute a == b
  end

  test "compute/1 differs when classification_type changes" do
    base = %{kind: :error, classification_type: :assertion, file: "f.exs", top_app_frame: "M.f/1"}

    a = Fingerprint.compute(base)
    b = Fingerprint.compute(%{base | classification_type: :function_clause})

    refute a == b
  end

  test "compute/1 differs when top_app_frame changes" do
    base = %{kind: :error, classification_type: :assertion, file: "f.exs", top_app_frame: "M.f/1"}

    a = Fingerprint.compute(base)
    b = Fingerprint.compute(%{base | top_app_frame: "M.g/2"})

    refute a == b
  end

  test "compute/1 normalizes nil and empty values" do
    a = Fingerprint.compute(%{kind: nil, classification_type: nil, file: nil, top_app_frame: nil})
    b = Fingerprint.compute(%{kind: "", classification_type: "", file: "", top_app_frame: ""})

    assert a == b
  end

  test "compute/1 accepts string keys" do
    fp =
      Fingerprint.compute(%{
        "kind" => :error,
        "classification_type" => :assertion,
        "file" => "f.exs",
        "top_app_frame" => "M.f/1"
      })

    assert byte_size(fp) == 64
  end

  test "compute/1 coerces atom values to strings" do
    fp =
      Fingerprint.compute(%{
        kind: :error,
        classification_type: :assertion,
        file: "f.exs",
        top_app_frame: :none
      })

    assert byte_size(fp) == 64
  end
end
