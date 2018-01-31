defmodule Cluster.Strategy.EpmdTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy.Epmd
  alias Cluster.Nodes

  import ExUnit.CaptureLog

  describe "start_link/1" do
    test "calls right functions" do
      capture_log(fn ->
        start_supervised(
          {Epmd,
           [
             topology: :name,
             config: [hosts: [:foo@bar]],
             connect: {Nodes, :connect, [self()]},
             list_nodes: {Nodes, :list_nodes, [[]]}
           ]}
        )

        assert_receive {:connect, :foo@bar}
      end)
    end
  end
end
