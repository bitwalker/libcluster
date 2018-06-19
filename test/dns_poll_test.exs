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
          topology: :dns_poll,
          config: [
            polling_interval: 100,
            query: "app",
            node_basename: "node",
            resolver: fn _query -> [{10, 0, 0, 1}, {10, 0, 0, 2}] end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[]]}
        ]
        |> DNSPoll.start_link()

        assert_receive {:connect, :"node@10.0.0.1"}, 100
        assert_receive {:connect, :"node@10.0.0.2"}, 100
      end)
    end
  end

  test "removes nodes" do
    capture_log(fn ->
      [
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
      ]
      |> DNSPoll.start_link()

      assert_receive {:disconnect, :"node@10.0.0.2"}, 100
    end)
  end

  test "keeps state" do
    capture_log(fn ->
      [
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
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, _}, 100
      refute_receive {:connect, _}, 100
    end)
  end

  test "does not connect to anything with missing config params" do
    capture_log(fn ->
      [
        topology: :dns_poll,
        config: [
          polling_interval: 100,
          resolver: fn _query -> [{10, 0, 0, 1}] end
        ],
        connect: {Nodes, :connect, [self()]},
        disconnect: {Nodes, :disconnect, [self()]},
        list_nodes: {Nodes, :list_nodes, [[]]}
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, _}, 100
      refute_receive {:connect, _}, 100
    end)
  end

  test "does not connect to anything with invalid config params" do
    capture_log(fn ->
      [
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
      ]
      |> DNSPoll.start_link()

      refute_receive {:disconnect, _}, 100
      refute_receive {:connect, _}, 100
    end)
  end
end
