defmodule Cluster.Strategy.KubernetesMembershipTest do
  use Cluster.HTTPSFixture, async: false

  alias Cluster.ConnectedNodes
  alias Cluster.Strategy.{Kubernetes, State}

  @moduletag capture_log: true

  setup context do
    nodes = start_supervised!({ConnectedNodes, self()})
    response = start_supervised!({Agent, fn -> %{"items" => []} end})
    port = start_https(context.valid, fn -> Agent.get(response, &Jason.encode!/1) end)

    state = %State{
      topology: :kubernetes_membership,
      config: [
        kubernetes_master: "localhost:#{port}",
        kubernetes_service_account_path: context.directory,
        kubernetes_namespace: "test",
        kubernetes_ip_lookup_mode: :pods,
        kubernetes_node_basename: "worker",
        kubernetes_selector: "app=worker",
        polling_interval: 60_000
      ],
      connect: {ConnectedNodes, :connect, [nodes]},
      disconnect: {ConnectedNodes, :disconnect, [nodes]},
      list_nodes: {ConnectedNodes, :list_nodes, [nodes]}
    }

    %{nodes: nodes, response: response, state: state}
  end

  test "discovers live unready pods but excludes deleting and terminal peers at startup",
       context do
    unready =
      pod("10.0.0.1")
      |> put_in(["metadata", "deletionTimestamp"], nil)
      |> put_in(["status", "conditions"], [%{"type" => "Ready", "status" => "False"}])

    deleting =
      put_in(pod("10.0.0.2"), ["metadata", "deletionTimestamp"], "2026-11-01T00:00:00Z")

    succeeded = put_in(pod("10.0.0.3"), ["status", "phase"], "Succeeded")
    failed = put_in(pod("10.0.0.4"), ["status", "phase"], "Failed")

    start_strategy(context, [unready, deleting, succeeded, failed])
    assert_received {:connect, :"worker@10.0.0.1"}
    refute_received {:connect, _}
    assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.1"]
  end

  test "preserves discovery of other nonterminal phases without readiness conditions", context do
    pods =
      for {ip, phase} <- [{"10.0.0.1", "Pending"}, {"10.0.0.2", "Unknown"}] do
        pod(ip)
        |> put_in(["status", "phase"], phase)
        |> update_in(["status"], &Map.delete(&1, "conditions"))
      end

    start_strategy(context, pods)
    assert_received {:connect, :"worker@10.0.0.1"}
    assert_received {:connect, :"worker@10.0.0.2"}
  end

  for {description, status} <- [
        {"missing", %{"phase" => "Pending"}},
        {"null", %{"phase" => "Pending", "podIP" => nil}},
        {"empty", %{"phase" => "Pending", "podIP" => ""}}
      ] do
    test "ignores a pod with a #{description} address while retaining healthy neighbors",
         context do
      invalid = Map.put(pod("10.0.0.2"), "status", unquote(Macro.escape(status)))
      start_strategy(context, [invalid, pod("10.0.0.1")])
      assert_received {:connect, :"worker@10.0.0.1"}
      refute_received {:connect, _}
      assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.1"]
    end
  end

  for {description, phase, deletion_timestamp} <- [
        {"deleting", "Running", "2026-11-01T00:00:00Z"},
        {"Succeeded", "Succeeded", nil},
        {"Failed", "Failed", nil}
      ] do
    test "disconnects a #{description} pod on the next successful poll", context do
      server = start_strategy(context, [pod("10.0.0.1"), pod("10.0.0.2")])
      assert_received {:connect, :"worker@10.0.0.1"}
      assert_received {:connect, :"worker@10.0.0.2"}

      excluded =
        pod("10.0.0.1")
        |> put_in(["status", "phase"], unquote(phase))
        |> put_in(["metadata", "deletionTimestamp"], unquote(deletion_timestamp))

      poll(context, server, [excluded, pod("10.0.0.2")])
      assert_received {:disconnect, :"worker@10.0.0.1"}
      refute_received {:disconnect, _}
      refute_received {:connect, _}
      assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.2"]

      poll(context, server, [excluded, pod("10.0.0.2")])
      refute_received {:connect, _}
      refute_received {:disconnect, _}
    end
  end

  test "retries a failed disconnection of a deleting pod", context do
    server = start_strategy(context, [pod("10.0.0.1"), pod("10.0.0.2")])
    assert_received {:connect, :"worker@10.0.0.1"}
    assert_received {:connect, :"worker@10.0.0.2"}
    ConnectedNodes.set_result(context.nodes, :disconnect, {:error, :busy})

    deleting =
      put_in(pod("10.0.0.1"), ["metadata", "deletionTimestamp"], "2026-11-01T00:00:00Z")

    poll(context, server, [deleting, pod("10.0.0.2")])
    assert_received {:disconnect, :"worker@10.0.0.1"}
    refute_received {:connect, _}

    assert Enum.sort(ConnectedNodes.list_nodes(context.nodes)) == [
             :"worker@10.0.0.1",
             :"worker@10.0.0.2"
           ]

    ConnectedNodes.set_result(context.nodes, :disconnect, true)
    poll(context, server, [deleting, pod("10.0.0.2")])
    assert_received {:disconnect, :"worker@10.0.0.1"}
    refute_received {:connect, _}
    assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.2"]
  end

  test "disconnects an endpoint moved out of ready addresses", context do
    first = %{"ip" => "10.0.0.1"}
    second = %{"ip" => "10.0.0.2"}

    endpoint = %{
      "metadata" => %{"namespace" => "test"},
      "subsets" => [%{"addresses" => [first, second]}]
    }

    server = start_strategy(context, [endpoint], kubernetes_ip_lookup_mode: :endpoints)
    assert_received {:connect, :"worker@10.0.0.1"}
    assert_received {:connect, :"worker@10.0.0.2"}

    updated =
      Map.put(endpoint, "subsets", [%{"addresses" => [second], "notReadyAddresses" => [first]}])

    poll(context, server, [updated])
    assert_received {:disconnect, :"worker@10.0.0.1"}
    refute_received {:connect, _}
    assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.2"]
  end

  defp pod(ip) do
    %{
      "metadata" => %{"namespace" => "test"},
      "spec" => %{"hostname" => "worker-0"},
      "status" => %{
        "podIP" => ip,
        "phase" => "Running",
        "conditions" => [%{"type" => "Ready", "status" => "True"}]
      }
    }
  end

  defp start_strategy(context, items, config \\ []) do
    Agent.update(context.response, fn _ -> %{"items" => items} end)
    state = %{context.state | config: Keyword.merge(context.state.config, config)}
    start_supervised!({Kubernetes, [state]})
  end

  defp poll(context, server, items) do
    Agent.update(context.response, fn _ -> %{"items" => items} end)
    send(server, :load)
    :sys.get_state(server)
  end
end
