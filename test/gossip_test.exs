defmodule Cluster.Strategy.GossipTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy.Gossip

  require Cluster.Nodes

  describe "start_link/1" do
    @tag capture_log: true
    test "starts GenServer and connects nodes" do
      {:ok, pid} =
        Gossip.start_link([
          %Cluster.Strategy.State{
            topology: :gossip,
            config: [
              port: 45892,
              if_addr: "127.0.0.1",
              multicast_if: "192.168.1.1",
              multicast_addr: "233.252.1.32",
              secret: "password"
            ],
            connect: {Cluster.Nodes, :connect, [self()]},
            list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
          }
        ])

      Process.sleep(1_000)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
