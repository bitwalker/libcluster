defmodule Cluster.Strategy.EpmdTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy.Epmd

  import ExUnit.CaptureLog

  describe "start_link/1" do
    test "calls right functions" do
      capture_log(fn ->
        :ignore = Epmd.start_link([%Cluster.Strategy.State{
             topology: :name,
             config: [hosts: [:"foo@bar"]],
             connect: {Cluster.Nodes, :connect, [self()]},
             list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
        }])

        assert_receive {:connect, :"foo@bar"}, 5_000
      end)
    end
  end
end
