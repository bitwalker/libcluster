defmodule Cluster.Strategy.KubernetesTerminationTest do
  use Cluster.HTTPSFixture, async: false

  alias Cluster.LocalPeer
  alias Cluster.Strategy.Kubernetes

  @moduletag capture_log: true
  unless Code.ensure_loaded?(:peer),
    do: @moduletag(skip: "Local distribution tests require OTP25+ :peer")

  setup context do
    unique = "#{System.pid()}_#{System.unique_integer([:positive])}"
    survivor_name = String.to_atom("survivor_#{unique}")
    departing_name = String.to_atom("departing_#{unique}")
    cookie = "libcluster_test_" <> Base.encode16(:crypto.strong_rand_bytes(16))
    {survivor, survivor_node} = LocalPeer.start(survivor_name, cookie)
    {departing, departing_node} = LocalPeer.start(departing_name, cookie)

    endpoints = %{"items" => [%{"subsets" => [%{"addresses" => [%{"ip" => "127.0.0.1"}]}]}]}
    response = start_supervised!({Agent, fn -> endpoints end})
    survivor_port = start_https(context.valid, fn -> Agent.get(response, &Jason.encode!/1) end)
    departing_port = start_https(context.valid, Jason.encode!(endpoints))

    survivor_config = config(context, departing_name, survivor_port)
    departing_config = config(context, survivor_name, departing_port)

    {survivor_root, survivor_cluster, survivor_workers} =
      start_discovery(survivor, peers: survivor_config)

    {departing_root, departing_cluster, departing_workers} =
      start_discovery(departing, first: departing_config, second: departing_config)

    assert_nodes(survivor, [departing_node])
    assert_nodes(departing, [survivor_node])

    %{
      survivor: survivor,
      survivor_node: survivor_node,
      departing: departing,
      departing_node: departing_node,
      survivor_root: survivor_root,
      survivor_cluster: survivor_cluster,
      survivor_workers: survivor_workers,
      departing_root: departing_root,
      departing_cluster: departing_cluster,
      departing_workers: departing_workers,
      response: response
    }
  end

  test "endpoint withdrawal alone allows the departing node to reconnect", context do
    withdraw(context)
    assert_nodes(context.survivor, [])
    assert_nodes(context.departing, [])

    LocalPeer.poll(context.departing, context.departing_workers[:first])
    assert_nodes(context.survivor, [context.departing_node])
    assert_nodes(context.departing, [context.survivor_node])

    for _ <- 1..3 do
      state = LocalPeer.poll(context.survivor, context.survivor_workers[:peers])
      assert state.meta == MapSet.new()
      assert_nodes(context.survivor, [context.departing_node])
    end
  end

  test "stopping one topology leaves another able to reconnect", context do
    :ok =
      LocalPeer.call(context.departing, Supervisor, :terminate_child, [
        context.departing_cluster,
        :first
      ])

    withdraw(context)
    assert_nodes(context.survivor, [])

    LocalPeer.poll(context.departing, context.departing_workers[:second])
    assert_nodes(context.survivor, [context.departing_node])
  end

  test "terminating the discovery supervisor prevents its workers from reconnecting", context do
    :ok =
      LocalPeer.call(context.departing, Supervisor, :terminate_child, [
        context.departing_root,
        Cluster.Supervisor
      ])

    # Stopping discovery does not itself close the existing distribution connection.
    assert_nodes(context.departing, [context.survivor_node])
    assert_discovery_stopped(context)

    withdraw(context)

    for _ <- 1..3 do
      LocalPeer.poll(context.survivor, context.survivor_workers[:peers])
      assert_nodes(context.survivor, [])
      assert_nodes(context.departing, [])
      assert_discovery_stopped(context)
    end
  end

  defp assert_discovery_stopped(context) do
    assert [{Cluster.Supervisor, :undefined, :supervisor, [Cluster.Supervisor]}] =
             LocalPeer.call(context.departing, Supervisor, :which_children, [
               context.departing_root
             ])

    assert LocalPeer.call(context.departing, Process, :alive?, [context.departing_root])

    for {_name, worker} <- context.departing_workers do
      refute LocalPeer.call(context.departing, Process, :alive?, [worker])
    end
  end

  defp withdraw(context) do
    Agent.update(context.response, fn _ -> %{"items" => []} end)
    LocalPeer.poll(context.survivor, context.survivor_workers[:peers])
    assert_nodes(context.survivor, [])
    assert_nodes(context.departing, [])
  end

  defp config(context, basename, port) do
    [
      kubernetes_master: "localhost:#{port}",
      kubernetes_service_account_path: context.directory,
      kubernetes_namespace: "test",
      kubernetes_node_basename: Atom.to_string(basename),
      kubernetes_selector: "app=#{basename}",
      polling_interval: 600_000
    ]
  end

  defp start_discovery(peer, configs) do
    topologies =
      Enum.map(configs, fn {name, config} ->
        {name, [strategy: Kubernetes, config: config]}
      end)

    # Use the public supervision tree and its default distribution callbacks.
    root = LocalPeer.call(peer, LocalPeer, :start_discovery, [topologies])

    [{Cluster.Supervisor, cluster, :supervisor, _}] =
      LocalPeer.call(peer, Supervisor, :which_children, [root])

    workers =
      LocalPeer.call(peer, Supervisor, :which_children, [cluster])
      |> Map.new(fn {name, pid, _, _} -> {name, pid} end)

    {root, cluster, workers}
  end

  defp assert_nodes(peer, expected) do
    assert :ok = LocalPeer.await_nodes(peer, expected)
    assert LocalPeer.call(peer, Node, :list, [:connected]) == expected
  end
end
