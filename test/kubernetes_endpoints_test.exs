defmodule Cluster.Strategy.KubernetesEndpointsTest do
  use Cluster.HTTPSFixture, async: false

  import ExUnit.CaptureLog

  alias Cluster.Strategy.Kubernetes
  alias Cluster.Strategy.State

  for reference <- [:missing, nil, %{}, %{"kind" => "Pod"}] do
    fields = if reference == :missing, do: %{}, else: %{"targetRef" => reference}

    test "accepts endpoint addresses with #{inspect(reference)} targetRef", context do
      address =
        Map.merge(
          %{"ip" => "10.0.0.2", "hostname" => "worker-0"},
          unquote(Macro.escape(fields))
        )

      response = %{
        "items" => [
          %{
            "metadata" => %{"namespace" => "endpoint-ns"},
            "subsets" => [%{"addresses" => [address]}]
          }
        ]
      }

      port = start_https(context.valid, Jason.encode!(response))

      capture_log(fn ->
        assert {:ok, _} = Kubernetes.init([state(:dns, context, port)])
      end)

      assert_receive {:connect, :"test@10-0-0-2.endpoint-ns.pod.cluster.local"}
    end
  end

  test "uses the request namespace when neither endpoint nor targetRef provides one", context do
    response = %{"items" => [%{"subsets" => [%{"addresses" => [%{"ip" => "10.0.0.2"}]}]}]}

    port = start_https(context.valid, Jason.encode!(response))

    capture_log(fn -> assert {:ok, _} = Kubernetes.init([state(:dns, context, port)]) end)

    assert_receive {:connect, :"test@10-0-0-2.query-ns.pod.cluster.local"}
  end

  test "keeps valid neighbors when an address cannot supply a hostname", context do
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

    port = start_https(context.valid, Jason.encode!(response))

    capture_log(fn -> assert {:ok, _} = Kubernetes.init([state(:hostname, context, port)]) end)

    assert_receive {:connect, :"test@worker-0.workers.pod-ns.svc.cluster.local"}
    refute_receive {:connect, _}
  end

  defp state(mode, context, port) do
    %State{
      topology: :endpoints_test,
      meta: MapSet.new(),
      config: [
        kubernetes_master: "localhost:#{port}",
        kubernetes_service_account_path: context.directory,
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
