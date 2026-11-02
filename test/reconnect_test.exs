defmodule Cluster.Strategy.ReconnectTest do
  use Cluster.HTTPSFixture, async: false

  alias Cluster.ConnectedNodes
  alias Cluster.Strategy.{Kubernetes, Rancher, State}
  alias Cluster.Strategy.Kubernetes.{DNS, DNSSRV}

  @moduletag capture_log: true
  @node :"worker@10.0.0.1"
  @neighbor :"worker@10.0.0.2"

  setup do
    %{
      nodes: start_supervised!({ConnectedNodes, self()}),
      addresses: start_supervised!({Agent, fn -> ["10.0.0.1", "10.0.0.2"] end})
    }
  end

  for mode <- [:endpoints, :pods, :endpoint_slices, :dns, :dns_srv, :rancher] do
    test "#{mode} reconnects a dropped peer with unchanged discovery", context do
      server = start_strategy(context, unquote(mode))
      assert_connected()

      assert MapSet.new(ConnectedNodes.list_nodes(context.nodes)) ==
               MapSet.new([@node, @neighbor])

      poll(server)
      refute_received {:connect, _}

      ConnectedNodes.set_connected(context.nodes, [@neighbor])
      poll(server)
      assert_received {:connect, @node}
      refute_received {:connect, _}

      assert MapSet.new(ConnectedNodes.list_nodes(context.nodes)) ==
               MapSet.new([@node, @neighbor])

      poll(server)
      refute_received {:connect, _}
      refute_received {:disconnect, _}
    end

    test "#{mode} retries a failed connection without a discovery change", context do
      ConnectedNodes.set_result(context.nodes, :connect, false)
      server = start_strategy(context, unquote(mode))
      assert_received {:connect, @node}
      assert_received {:connect, @neighbor}
      drain_initial_attempts()
      assert ConnectedNodes.list_nodes(context.nodes) == []

      ConnectedNodes.set_result(context.nodes, :connect, true)
      poll(server)
      assert_connected()

      assert MapSet.new(ConnectedNodes.list_nodes(context.nodes)) ==
               MapSet.new([@node, @neighbor])

      poll(server)
      refute_received {:connect, _}
      refute_received {:disconnect, _}
    end

    test "#{mode} retries a failed disconnection while keeping healthy neighbors", context do
      server = start_strategy(context, unquote(mode))
      assert_connected()
      ConnectedNodes.set_result(context.nodes, :disconnect, {:error, :busy})
      Agent.update(context.addresses, fn _ -> ["10.0.0.2"] end)

      poll(server)
      assert_received {:disconnect, @node}
      refute_received {:connect, _}

      assert MapSet.new(ConnectedNodes.list_nodes(context.nodes)) ==
               MapSet.new([@node, @neighbor])

      ConnectedNodes.set_result(context.nodes, :disconnect, true)
      poll(server)
      assert_received {:disconnect, @node}
      refute_received {:connect, _}
      assert ConnectedNodes.list_nodes(context.nodes) == [@neighbor]

      poll(server)
      refute_received {:disconnect, _}
      refute_received {:connect, _}
    end
  end

  defp start_strategy(context, mode) do
    {strategy, config} = discovery(context, mode)

    state = %State{
      topology: :reconnect,
      config: [polling_interval: 60_000] ++ config,
      connect: {ConnectedNodes, :connect, [context.nodes]},
      disconnect: {ConnectedNodes, :disconnect, [context.nodes]},
      list_nodes: {ConnectedNodes, :list_nodes, [context.nodes]}
    }

    server = start_supervised!({strategy, [state]})
    # DNS strategies issue an immediate timeout after init. Complete it before
    # changing connection state, so only explicit polls drive the regression.
    poll(server)

    if mode == :rancher do
      assert_received {:http_request, request}
      assert request =~ "GET http://rancher-metadata/latest/self/service HTTP/1.1\r\n"
      assert request =~ "accept: application/json"
    end

    server
  end

  defp discovery(context, :dns) do
    resolver = fn ~c"workers" ->
      addresses =
        Agent.get(
          context.addresses,
          &Enum.map(&1, fn ip ->
            ip |> String.to_charlist() |> :inet.parse_address() |> elem(1)
          end)
        )

      {:ok, {:hostent, ~c"workers", [], :inet, 4, addresses}}
    end

    {DNS, [application_name: "worker", service: "workers", resolver: resolver]}
  end

  defp discovery(context, :dns_srv) do
    resolver = fn _query ->
      addresses =
        Agent.get(
          context.addresses,
          &Enum.map(&1, fn ip -> {0, 0, 0, String.to_charlist(ip)} end)
        )

      {:ok, {:hostent, ~c"workers", [], :srv, length(addresses), addresses}}
    end

    {DNSSRV,
     [application_name: "worker", service: "workers", namespace: "test", resolver: resolver]}
  end

  defp discovery(context, :rancher) do
    Cluster.HTTPFixture.start_proxy(fn ->
      context.addresses
      |> Agent.get(&%{"containers" => Enum.map(&1, fn ip -> %{"ips" => [ip]} end)})
      |> Jason.encode!()
    end)

    {Rancher, [node_basename: "worker"]}
  end

  defp discovery(context, mode) do
    port =
      start_https(context.valid, fn ->
        ips = Agent.get(context.addresses, & &1)
        Jason.encode!(response(mode, ips))
      end)

    {Kubernetes,
     [
       kubernetes_master: "localhost:#{port}",
       kubernetes_service_account_path: context.directory,
       kubernetes_namespace: "test",
       kubernetes_ip_lookup_mode: mode,
       kubernetes_node_basename: "worker",
       kubernetes_selector: "app=worker"
     ]}
  end

  defp response(:endpoints, ips) do
    %{"items" => [%{"subsets" => [%{"addresses" => Enum.map(ips, &%{"ip" => &1})}]}]}
  end

  defp response(:pods, ips) do
    %{
      "items" =>
        Enum.map(
          ips,
          &%{"metadata" => %{"namespace" => "test"}, "spec" => %{}, "status" => %{"podIP" => &1}}
        )
    }
  end

  defp response(:endpoint_slices, ips) do
    %{
      "items" => [
        %{"addressType" => "IPv4", "endpoints" => Enum.map(ips, &%{"addresses" => [&1]})}
      ]
    }
  end

  defp assert_connected do
    assert_received {:connect, @node}
    assert_received {:connect, @neighbor}
    refute_received {:connect, _}
  end

  defp drain_initial_attempts do
    receive do
      {:connect, node} when node in [@node, @neighbor] -> drain_initial_attempts()
    after
      0 -> :ok
    end
  end

  defp poll(server) do
    send(server, :load)
    :sys.get_state(server)
  end
end
