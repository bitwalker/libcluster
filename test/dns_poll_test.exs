defmodule Cluster.Strategy.DNSPollTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Cluster.Nodes
  alias Cluster.ConnectedNodes
  alias Cluster.Strategy.DNSPoll
  alias Cluster.Strategy.State

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

  describe "polling membership" do
    @describetag capture_log: true

    setup do
      nodes = start_supervised!({ConnectedNodes, self()})
      answers = start_supervised!({Agent, fn -> [] end})

      state = %State{
        topology: :dns_poll,
        config: [
          polling_interval: 60_000,
          query: "app",
          node_basename: "node",
          resolver: fn _query -> Agent.get(answers, & &1) end
        ],
        connect: {ConnectedNodes, :connect, [nodes]},
        disconnect: {ConnectedNodes, :disconnect, [nodes]},
        list_nodes: {ConnectedNodes, :list_nodes, [nodes]}
      }

      %{state: state, nodes: nodes, answers: answers}
    end

    test "keeps earlier peers connected across rotating answers when pruning is disabled",
         context do
      server = start_polling(context, [{10, 0, 0, 1}], prune: false)
      assert_received {:connect, :"node@10.0.0.1"}

      poll(server, context.answers, [{10, 0, 0, 2}])
      assert_received {:connect, :"node@10.0.0.2"}
      refute_received {:disconnect, _}

      assert Enum.sort(ConnectedNodes.list_nodes(context.nodes)) == [
               :"node@10.0.0.1",
               :"node@10.0.0.2"
             ]

      poll(server, context.answers, [{10, 0, 0, 2}, {10, 0, 0, 3}])
      assert_received {:connect, :"node@10.0.0.3"}
      refute_received {:connect, _}
      refute_received {:disconnect, _}

      assert Enum.sort(ConnectedNodes.list_nodes(context.nodes)) == [
               :"node@10.0.0.1",
               :"node@10.0.0.2",
               :"node@10.0.0.3"
             ]
    end

    for config <- [[], [prune: true]] do
      test "prunes absent peers and empty answers with #{inspect(config)}", context do
        server = start_polling(context, [{10, 0, 0, 1}], unquote(config))
        assert_received {:connect, :"node@10.0.0.1"}

        poll(server, context.answers, [{10, 0, 0, 2}])
        assert_received {:disconnect, :"node@10.0.0.1"}
        assert_received {:connect, :"node@10.0.0.2"}
        assert ConnectedNodes.list_nodes(context.nodes) == [:"node@10.0.0.2"]

        poll(server, context.answers, [])
        assert_received {:disconnect, :"node@10.0.0.2"}
        assert ConnectedNodes.list_nodes(context.nodes) == []
      end
    end

    test "does not disconnect on an empty answer when pruning is disabled", context do
      server = start_polling(context, [{10, 0, 0, 1}], prune: false)
      assert_received {:connect, :"node@10.0.0.1"}

      poll(server, context.answers, [])
      refute_received {:disconnect, _}
      assert ConnectedNodes.list_nodes(context.nodes) == [:"node@10.0.0.1"]
    end

    for prune <- [true, false] do
      test "reconnects a dropped peer with unchanged discovery and prune: #{prune}", context do
        server = start_polling(context, [{10, 0, 0, 1}], prune: unquote(prune))
        assert_received {:connect, :"node@10.0.0.1"}

        ConnectedNodes.set_connected(context.nodes, [])
        poll(server, context.answers, [{10, 0, 0, 1}])
        assert_received {:connect, :"node@10.0.0.1"}
        assert ConnectedNodes.list_nodes(context.nodes) == [:"node@10.0.0.1"]

        poll(server, context.answers, [{10, 0, 0, 1}])
        refute_received {:connect, _}
        refute_received {:disconnect, _}
      end
    end

    test "retries a failed connection on the next unchanged answer", context do
      ConnectedNodes.set_result(context.nodes, :connect, false)
      server = start_polling(context, [{10, 0, 0, 1}])
      assert_received {:connect, :"node@10.0.0.1"}
      assert ConnectedNodes.list_nodes(context.nodes) == []

      ConnectedNodes.set_result(context.nodes, :connect, true)
      poll(server, context.answers, [{10, 0, 0, 1}])
      assert_received {:connect, :"node@10.0.0.1"}
      assert ConnectedNodes.list_nodes(context.nodes) == [:"node@10.0.0.1"]
    end

    test "retries a failed disconnection on the next poll", context do
      server = start_polling(context, [{10, 0, 0, 1}])
      assert_received {:connect, :"node@10.0.0.1"}

      ConnectedNodes.set_result(context.nodes, :disconnect, {:error, :blocked})
      poll(server, context.answers, [{10, 0, 0, 2}])
      assert_received {:disconnect, :"node@10.0.0.1"}
      assert_received {:connect, :"node@10.0.0.2"}

      assert Enum.sort(ConnectedNodes.list_nodes(context.nodes)) == [
               :"node@10.0.0.1",
               :"node@10.0.0.2"
             ]

      ConnectedNodes.set_result(context.nodes, :disconnect, true)
      poll(server, context.answers, [{10, 0, 0, 2}])
      assert_received {:disconnect, :"node@10.0.0.1"}
      refute_received {:connect, _}
      assert ConnectedNodes.list_nodes(context.nodes) == [:"node@10.0.0.2"]
    end

    test "only retries a historical peer when it is rediscovered with pruning disabled",
         context do
      server = start_polling(context, [{10, 0, 0, 1}], prune: false)
      assert_received {:connect, :"node@10.0.0.1"}

      poll(server, context.answers, [{10, 0, 0, 2}])
      assert_received {:connect, :"node@10.0.0.2"}
      ConnectedNodes.set_connected(context.nodes, [:"node@10.0.0.2"])

      poll(server, context.answers, [{10, 0, 0, 2}])
      refute_received {:connect, _}

      poll(server, context.answers, [{10, 0, 0, 1}])
      assert_received {:connect, :"node@10.0.0.1"}
      refute_received {:disconnect, _}

      assert Enum.sort(ConnectedNodes.list_nodes(context.nodes)) == [
               :"node@10.0.0.1",
               :"node@10.0.0.2"
             ]
    end
  end

  defp start_polling(context, answer, config \\ []) do
    Agent.update(context.answers, fn _ -> answer end)
    state = %{context.state | config: Keyword.merge(context.state.config, config)}
    start_supervised!({DNSPoll, [state]})
  end

  defp poll(server, answers, answer) do
    Agent.update(answers, fn _ -> answer end)
    send(server, :poll)
    :sys.get_state(server)
  end
end
