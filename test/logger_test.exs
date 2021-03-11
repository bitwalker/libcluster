defmodule Cluster.LoggerTest do
  @moduledoc false

  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Cluster.Logger
  Application.put_env(:libcluster, :debug, true)

  for level <- [:debug, :info, :warn, :error] do
    describe "#{level}/2" do
      test "logs correctly" do
        output =
          capture_log(fn ->
            apply(Logger, unquote(level), [
              __MODULE__,
              "some message"
            ])
          end)

        assert output =~ "[#{unquote(level)}]"
        assert output =~ "[libcluster:Elixir.Cluster.LoggerTest] some message"
      end
    end
  end

  describe "debug_inspect/2" do
    setup do
      Application.put_env(:libcluster, :debug, 1)
    end

    test "with label" do
      output =
        capture_log(fn ->
          %{foo: "bar"} |> Logger.debug_inspect(__MODULE__, label: "value")
        end)

      assert output =~ ~s|[libcluster:Elixir.Cluster.LoggerTest] value: %{foo: "bar"}|
    end

    test "without label" do
      output =
        capture_log(fn ->
          %{foo: "bar"} |> Logger.debug_inspect(__MODULE__)
        end)

      assert output =~ ~s|[libcluster:Elixir.Cluster.LoggerTest] %{foo: "bar"}|
    end

    test "ignore if level is too low" do
      output =
        capture_log(fn ->
          %{foo: "bar"} |> Logger.debug_inspect(__MODULE__, label: "value", verbose: 2)
        end)

      assert output == ""
    end
  end
end
