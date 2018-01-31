defmodule Cluster.LoggerTest do
  @moduledoc false

  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Cluster.Logger

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
end
