defmodule TestLens.FailureClassifierTest do
  use ExUnit.Case, async: true

  alias TestLens.Classifier

  # Mock exception modules for library-specific exceptions.
  # These use the same atom names that the real libraries use,
  # allowing string-matching in adapters to work in both test and production.

  defmodule Ecto.ConstraintError do
    defexception [:type, :constraint, :message]
  end

  defmodule DBConnection.ConnectionError do
    defexception [:message]
  end

  defmodule Phoenix.Router.NoRouteError do
    defexception [:verb, :path, :message]
  end

  defmodule Phoenix.LiveView.RenderError do
    defexception [:message]
  end

  defmodule Mox.UnexpectedCallError do
    defexception [:message]
  end

  defmodule Mox.VerificationError do
    defexception [:message]
  end

  defmodule SomeUnknownError do
    defexception [:message]
  end

  # Helper to assert classification structure
  defp assert_classification(c, expected_type, expected_severity) do
    assert c.type == expected_type
    assert is_binary(c.likely_layer) and c.likely_layer != ""
    assert is_binary(c.plain_english) and c.plain_english != ""
    assert is_list(c.common_causes) and c.common_causes != []
    assert is_list(c.suggested_checks) and c.suggested_checks != []
    assert c.default_severity == expected_severity
  end

  describe "classify_failure/1 - timeout" do
    test ":exit :timeout matches Timeout adapter with critical severity" do
      failure = {:exit, :timeout, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :timeout, :critical)
    end

    test ":exit {:timeout, _} matches Timeout adapter" do
      failure = {:exit, {:timeout, 5000}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :timeout, :critical)
    end

    test "ExUnit.AssertionError with timeout in message does not match Timeout adapter (no timeout in message)" do
      # This assertion error does NOT contain "timeout" in the message,
      # so it should fall through to the Assertion adapter, not Timeout
      failure = {:error, %ExUnit.AssertionError{message: "expected 1 to equal 1", left: 1, right: 1}, []}
      c = Classifier.classify_failure(failure)
      assert c.type == :assertion
    end
  end

  describe "classify_failure/1 - mock" do
    test "Mox.UnexpectedCallError matches Mock adapter" do
      failure = {:error, %Mox.UnexpectedCallError{message: "unexpected call"}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :mock, :other)
    end

    test "Mox.VerificationError matches Mock adapter" do
      failure = {:error, %Mox.VerificationError{message: "verification failed"}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :mock, :other)
    end
  end

  describe "classify_failure/1 - ecto_constraint" do
    test "Ecto.ConstraintError matches EctoConstraint adapter" do
      failure = {:error, %Ecto.ConstraintError{type: :unique, constraint: "x", message: "constraint error"}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :ecto_constraint, :other)
    end
  end

  describe "classify_failure/1 - ecto_sandbox" do
    test "DBConnection.ConnectionError matches EctoSandbox adapter" do
      failure = {:error, %DBConnection.ConnectionError{message: "no connection"}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :ecto_sandbox, :other)
    end
  end

  describe "classify_failure/1 - phoenix_route" do
    test "Phoenix.Router.NoRouteError matches PhoenixRoute adapter" do
      failure = {:error, %Phoenix.Router.NoRouteError{verb: "GET", path: "/x", message: "no route"}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :phoenix_route, :other)
    end
  end

  describe "classify_failure/1 - live_view_render" do
    test "Phoenix.LiveView.RenderError matches LiveViewRender adapter" do
      failure = {:error, %Phoenix.LiveView.RenderError{}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :live_view_render, :other)
    end
  end

  describe "classify_failure/1 - process_exit" do
    test ":exit :killed matches ProcessExit adapter with critical severity" do
      failure = {:exit, :killed, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :process_exit, :critical)
    end

    test ":exit :normal matches ProcessExit adapter" do
      failure = {:exit, :normal, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :process_exit, :critical)
    end

    test ":exit {:shutdown, _} matches ProcessExit adapter" do
      failure = {:exit, {:shutdown, :shutdown}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :process_exit, :critical)
    end
  end

  describe "classify_failure/1 - match_error" do
    test "MatchError matches MatchError adapter" do
      failure = {:error, %MatchError{term: :nope}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :match_error, :other)
    end
  end

  describe "classify_failure/1 - function_clause" do
    test "FunctionClauseError matches FunctionClause adapter" do
      failure = {:error, %FunctionClauseError{module: SomeMod, function: :foo, arity: 1}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :function_clause, :other)
    end
  end

  describe "classify_failure/1 - case_clause" do
    test "CaseClauseError matches CaseClause adapter" do
      failure = {:error, %CaseClauseError{term: :nope}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :case_clause, :other)
    end
  end

  describe "classify_failure/1 - undefined_function" do
    test "UndefinedFunctionError matches UndefinedFunction adapter" do
      failure = {:error, %UndefinedFunctionError{module: SomeMod, function: :bar, arity: 2}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :undefined_function, :other)
    end
  end

  describe "classify_failure/1 - assertion" do
    test "ExUnit.AssertionError matches Assertion adapter" do
      failure = {:error, %ExUnit.AssertionError{}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :assertion, :other)
    end
  end

  describe "classify_failure/1 - unknown" do
    test "SomeUnknownError matches Unknown adapter" do
      failure = {:error, %SomeUnknownError{message: "something went wrong"}, []}
      c = Classifier.classify_failure(failure)
      assert_classification(c, :unknown, :other)
    end
  end

  describe "classify_failure/1 - determinism" do
    test "returns identical result for 100 consecutive calls with same input" do
      failure = {:exit, :timeout, []}
      results = for _ <- 1..100, do: Classifier.classify_failure(failure)
      Enum.each(results, fn r -> assert r == hd(results) end)
    end

    test "returns identical result for MatchError across 100 calls" do
      failure = {:error, %MatchError{term: :nope}, []}
      results = for _ <- 1..100, do: Classifier.classify_failure(failure)
      Enum.each(results, fn r -> assert r == hd(results) end)
    end
  end

  describe "register_failure_adapter/1" do
    defmodule CustomAdapter do
      def match?({:error, %{__exception__: true, __struct__: struct}, _stacktrace}) do
        to_string(struct) |> String.contains?("CustomError")
      end

      def match?(_), do: false

      def details do
        %{
          type: :custom,
          likely_layer: "Custom",
          plain_english: "A custom error we classified.",
          common_causes: ["custom cause"],
          suggested_checks: ["check custom"],
          default_severity: :other
        }
      end
    end

    defmodule CustomError do
      defexception [:message]
    end

    test "prepends user adapter so it takes precedence" do
      Classifier.register_failure_adapter(CustomAdapter)
      failure = {:error, %CustomError{message: "custom"}, []}
      c = Classifier.classify_failure(failure)
      assert c.type == :custom
      # Clean up
      Process.delete(:tl_failure_adapters)
    end
  end
end