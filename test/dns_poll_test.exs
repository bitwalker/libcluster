defmodule Cluster.Strategy.DNSPollTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Cluster.Nodes
  alias Cluster.Strategy.DNSPoll

  describe "start_link/1" do
    test "adds new nodes" do
      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dns_poll,
            config: [
              polling_interval: 100,
              query: "app",
              node_basename: "node",
              resolver: fn _query ->
                [{10, 0, 0, 1}, {10, 0, 0, 2}, {10761, 33408, 1, 41584, 47349, 47607, 34961, 243}]
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DNSPoll.start_link()

        assert_receive {:connect, :"node@10.0.0.1"}, 100
        assert_receive {:connect, :"node@10.0.0.2"}, 100
        assert_receive {:connect, :"node@2a09:8280:1:a270:b8f5:b9f7:8891:f3"}, 100
      end)
    end
  end

  test "removes nodes" do
    capture_log(fn ->
      [
        %Cluster.Strategy.State{
          topology: :dns_poll,
          config: [
            polling_interval: 100,
            query: "app",
            node_basename: "node",
            resolver: fn _query -> [{10, 0, 0, 1}] end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[:"node@10.0.0.1", :"node@10.0.0.2"]]},
          meta: MapSet.new([:"node@10.0.0.1", :"node@10.0.0.2"])
        }
      ]
      |> DNSPoll.start_link()

      assert_receive {:disconnect, :"node@10.0.0.2"}, 100
    end)
  end

  test "keep missing nodes when prune is false" do
    capture_log(fn ->
      [
        %Cluster.Strategy.State{
          topology: :dns_poll,
          config: [
            polling_interval: 100,
            query: "app",
            node_basename: "node",
            prune: false,
            resolver: fn _query -> [{10, 0, 0, 1}] end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[:"node@10.0.0.1", :"node@10.0.0.2"]]},
          meta: MapSet.new([:"node@10.0.0.1", :"node@10.0.0.2"])
        }
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, :"node@10.0.0.2"}, 100
    end)
  end

  test "keeps state" do
    capture_log(fn ->
      [
        %Cluster.Strategy.State{
          topology: :dns_poll,
          config: [
            polling_interval: 100,
            query: "app",
            node_basename: "node",
            resolver: fn _query -> [{10, 0, 0, 1}] end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[:"node@10.0.0.1"]]},
          meta: MapSet.new([:"node@10.0.0.1"])
        }
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, _}, 100
      refute_receive {:connect, _}, 100
    end)
  end

  test "does not connect to anything with missing config params" do
    capture_log(fn ->
      [
        %Cluster.Strategy.State{
          topology: :dns_poll,
          config: [
            polling_interval: 100,
            resolver: fn _query -> [{10, 0, 0, 1}] end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[]]}
        }
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, _}, 100
      refute_receive {:connect, _}, 100
    end)
  end

  test "does not connect to anything with invalid config params" do
    capture_log(fn ->
      [
        %Cluster.Strategy.State{
          topology: :dns_poll,
          config: [
            query: :app,
            node_basename: "",
            polling_interval: 100,
            resolver: fn _query -> [{10, 0, 0, 1}] end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[]]}
        }
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, _}, 100
      refute_receive {:connect, _}, 100
    end)
  end

  test "looks up both A and AAAA records" do
    result = DNSPoll.lookup_all_ips("example.org" |> String.to_charlist())
    sizes = result |> Enum.map(fn ip -> tuple_size(ip) end) |> Enum.uniq() |> Enum.sort()
    assert(sizes == [4, 8])
  end
end
