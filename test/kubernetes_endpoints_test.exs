defmodule Cluster.Strategy.KubernetesEndpointsTest do
  use ExUnit.Case, async: false
  use ExVCR.Mock, adapter: ExVCR.Adapter.Httpc

  import ExUnit.CaptureLog

  alias Cluster.Strategy.Kubernetes
  alias Cluster.Strategy.State

  require Cluster.Nodes

  for reference <- [:missing, nil, %{}, %{"kind" => "Pod"}] do
    test "accepts endpoint addresses with #{inspect(reference)} targetRef" do
      address = %{"ip" => "10.0.0.2", "hostname" => "worker-0"}
      reference = unquote(Macro.escape(reference))

      address =
        if reference == :missing, do: address, else: Map.put(address, "targetRef", reference)

      response = %{
        "items" => [
          %{
            "metadata" => %{"namespace" => "endpoint-ns"},
            "subsets" => [%{"addresses" => [address]}]
          }
        ]
      }

      use_cassette :stub,
        url:
          "https://cluster.localhost./api/v1/namespaces/query-ns/endpoints?labelSelector=app%3Dtest",
        body: Jason.encode!(response) do
        capture_log(fn ->
          assert {:ok, _} = Kubernetes.init([state(:dns)])
        end)
      end

      assert_receive {:connect, :"test@10-0-0-2.endpoint-ns.pod.cluster.local"}
    end
  end

  test "uses the request namespace when neither endpoint nor targetRef provides one" do
    response = %{"items" => [%{"subsets" => [%{"addresses" => [%{"ip" => "10.0.0.2"}]}]}]}

    use_cassette :stub,
      url:
        "https://cluster.localhost./api/v1/namespaces/query-ns/endpoints?labelSelector=app%3Dtest",
      body: Jason.encode!(response) do
      capture_log(fn -> assert {:ok, _} = Kubernetes.init([state(:dns)]) end)
    end

    assert_receive {:connect, :"test@10-0-0-2.query-ns.pod.cluster.local"}
  end

  test "keeps valid neighbors when an address cannot supply a hostname" do
    response = %{
      "items" => [
        %{
          "metadata" => %{"namespace" => "endpoint-ns"},
          "subsets" => [
            %{
              "addresses" => [
                %{"ip" => "10.0.0.1"},
                %{
                  "ip" => "10.0.0.2",
                  "hostname" => "worker-0",
                  "targetRef" => %{"namespace" => "pod-ns"}
                }
              ]
            }
          ]
        }
      ]
    }

    use_cassette :stub,
      url:
        "https://cluster.localhost./api/v1/namespaces/query-ns/endpoints?labelSelector=app%3Dtest",
      body: Jason.encode!(response) do
      capture_log(fn -> assert {:ok, _} = Kubernetes.init([state(:hostname)]) end)
    end

    assert_receive {:connect, :"test@worker-0.workers.pod-ns.svc.cluster.local"}
    refute_receive {:connect, _}
  end

  defp state(mode) do
    %State{
      topology: :endpoints_test,
      meta: MapSet.new(),
      config: [
        kubernetes_master: "cluster.localhost.",
        kubernetes_namespace: "query-ns",
        kubernetes_selector: "app=test",
        kubernetes_node_basename: "test",
        kubernetes_service_name: "workers",
        mode: mode,
        polling_interval: 60_000
      ],
      connect: {Cluster.Nodes, :connect, [self()]},
      disconnect: {Cluster.Nodes, :disconnect, [self()]},
      list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
    }
  end
end
