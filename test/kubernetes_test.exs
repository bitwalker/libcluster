defmodule Cluster.Strategy.KubernetesTest do
  @moduledoc false
  use Cluster.HTTPSFixture, async: false

  alias Cluster.Strategy.Kubernetes
  alias Cluster.Strategy.State

  @moduletag capture_log: true

  test "discovers endpoints through the authenticated HTTPS API", context do
    start_strategy(context)
    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    request =
      assert_request("/api/v1/namespaces/__libcluster_test/endpoints", %{
        "labelSelector" => "app=test_selector"
      })

    assert request =~ ~r/authorization: Bearer dummy-token/i
  end

  test "uses the configured namespace", context do
    start_strategy(context, kubernetes_namespace: "airatel-service-test")
    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    assert_request("/api/v1/namespaces/airatel-service-test/endpoints", %{
      "labelSelector" => "app=test_selector"
    })
  end

  test "requests cached endpoint resources", context do
    start_strategy(context, kubernetes_use_cached_resources: true)
    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    assert_request("/api/v1/namespaces/__libcluster_test/endpoints", %{
      "labelSelector" => "app=test_selector",
      "resourceVersion" => "0"
    })
  end

  test "omits the resource version when caching is explicitly disabled", context do
    start_strategy(context, kubernetes_use_cached_resources: false)
    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    assert_request("/api/v1/namespaces/__libcluster_test/endpoints", %{
      "labelSelector" => "app=test_selector"
    })
  end

  test "escapes label selector query values", context do
    start_strategy(context, kubernetes_selector: "app in (alpha,beta),role=web")
    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    assert_request("/api/v1/namespaces/__libcluster_test/endpoints", %{
      "labelSelector" => "app in (alpha,beta),role=web"
    })
  end

  test "formats DNS names with the configured cluster name", context do
    start_strategy(context, mode: :dns, kubernetes_cluster_name: "my_cluster")

    assert_receive {:connect,
                    :"test_basename@10-48-33-136.airatel-service-localization.pod.my_cluster.local"},
                   5_000
  end

  test "formats endpoint hostnames with the configured service and cluster", context do
    start_strategy(context,
      mode: :hostname,
      kubernetes_service_name: "my_service",
      kubernetes_cluster_name: "my_cluster"
    )

    assert_receive {:connect,
                    :"test_basename@my-hostname-0.my_service.airatel-service-localization.svc.my_cluster.local"},
                   5_000
  end

  test "formats pod hostnames with the configured service and cluster", context do
    start_strategy(context,
      kubernetes_ip_lookup_mode: :pods,
      mode: :hostname,
      kubernetes_service_name: "my_service",
      kubernetes_cluster_name: "my_cluster"
    )

    assert_receive {:connect,
                    :"test_basename@my-hostname-0.my_service.airatel-service-localization.svc.my_cluster.local"},
                   5_000
  end

  test "discovers pods through the pods API", context do
    start_strategy(context, kubernetes_ip_lookup_mode: :pods)
    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    assert_request("/api/v1/namespaces/__libcluster_test/pods", %{
      "labelSelector" => "app=test_selector"
    })
  end

  test "requests cached pod resources", context do
    start_strategy(context,
      kubernetes_ip_lookup_mode: :pods,
      kubernetes_use_cached_resources: true
    )

    assert_receive {:connect, :"test_basename@10.48.33.136"}, 5_000

    assert_request("/api/v1/namespaces/__libcluster_test/pods", %{
      "labelSelector" => "app=test_selector",
      "resourceVersion" => "0"
    })
  end

  test "formats pod DNS names", context do
    start_strategy(context, kubernetes_ip_lookup_mode: :pods, mode: :dns)

    assert_receive {:connect,
                    :"test_basename@10-48-33-136.airatel-service-localization.pod.cluster.local"},
                   5_000
  end

  test "preserves membership during an API outage", context do
    port = start_https(context.valid, "temporarily unavailable", 503)
    previous = MapSet.new([:"existing@10.0.0.1"])
    assert {:ok, loaded} = Kubernetes.init([state(context, port, [], previous)])
    assert loaded.meta == previous

    assert_request("/api/v1/namespaces/__libcluster_test/endpoints", %{
      "labelSelector" => "app=test_selector"
    })

    refute_receive {:disconnect, _}
  end

  defp start_strategy(context, config \\ []) do
    resource = Keyword.get(config, :kubernetes_ip_lookup_mode, :endpoints)
    body = File.read!(Path.join([__DIR__, "fixtures", "kubernetes", "#{resource}.json"]))
    port = start_https(context.valid, body)
    start_supervised!({Kubernetes, [state(context, port, config, MapSet.new())]})
  end

  defp state(context, port, config, meta) do
    %State{
      topology: :name,
      meta: meta,
      config:
        Keyword.merge(
          [
            kubernetes_master: "localhost:#{port}",
            kubernetes_service_account_path: context.directory,
            kubernetes_node_basename: "test_basename",
            kubernetes_selector: "app=test_selector",
            polling_interval: 60_000
          ],
          config
        ),
      connect: {Cluster.Nodes, :connect, [self()]},
      disconnect: {Cluster.Nodes, :disconnect, [self()]},
      list_nodes: {Cluster.Nodes, :list_nodes, [MapSet.to_list(meta)]}
    }
  end

  defp assert_request(path, query) do
    assert_receive {:tls_request, request}, 5_000
    ["GET", target, "HTTP/1.1" | _] = String.split(request, [" ", "\r\n"])
    uri = URI.parse(target)
    assert uri.path == path
    assert URI.decode_query(uri.query) == query
    request
  end
end
