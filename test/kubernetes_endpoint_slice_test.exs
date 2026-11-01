defmodule Cluster.Strategy.KubernetesEndpointSliceTest do
  @moduledoc false
  use Cluster.HTTPSFixture, async: false

  alias Cluster.ConnectedNodes
  alias Cluster.Strategy.{Kubernetes, State}

  @moduletag capture_log: true
  @path "/apis/discovery.k8s.io/v1/namespaces/test/endpointslices"
  @selector "kubernetes.io/service-name=myapp"

  setup context do
    nodes = start_supervised!({ConnectedNodes, self()})
    responses = start_supervised!({Agent, fn -> [] end})

    port =
      start_https(context.valid, fn ->
        Agent.get_and_update(responses, fn [{status, body} = current | rest] ->
          encoded = if is_binary(body), do: body, else: Jason.encode!(body)
          {{status, encoded}, if(rest == [], do: [current], else: rest)}
        end)
      end)

    state = %State{
      topology: :endpoint_slices,
      config: [
        kubernetes_master: "localhost:#{port}",
        kubernetes_service_account_path: context.directory,
        kubernetes_namespace: "test",
        kubernetes_ip_lookup_mode: :endpoint_slices,
        kubernetes_node_basename: "worker",
        kubernetes_selector: @selector,
        polling_interval: 60_000
      ],
      connect: {ConnectedNodes, :connect, [nodes]},
      disconnect: {ConnectedNodes, :disconnect, [nodes]},
      list_nodes: {ConnectedNodes, :list_nodes, [nodes]}
    }

    %{nodes: nodes, responses: responses, state: state}
  end

  test "aggregates every page and deduplicates overlapping dual-stack endpoints", context do
    pages = [
      {200, page([slice("IPv4", [%{"addresses" => ["10.0.0.1", "10.0.0.2"]}])], "next+/=")},
      {200,
       page([
         slice("IPv4", [%{"addresses" => ["10.0.0.1"]}]),
         slice("IPv6", [%{"addresses" => ["2001:db8::1"]}])
       ])}
    ]

    start_strategy(context, pages)
    assert_received {:connect, :"worker@10.0.0.1"}
    assert_received {:connect, :"worker@10.0.0.2"}
    assert_received {:connect, :"worker@2001:db8::1"}
    refute_received {:connect, _}

    request = assert_request(%{"labelSelector" => @selector, "limit" => "500"})
    assert request =~ ~r/authorization: Bearer dummy-token/i

    assert_request(%{"labelSelector" => @selector, "limit" => "500", "continue" => "next+/="})
    refute_received {:tls_request, _}
  end

  test "continues an empty cached page without carrying resourceVersion into the next request",
       context do
    start_strategy(
      context,
      [{200, page([], "next")}, {200, page([slice("IPv4", [%{"addresses" => ["10.0.0.1"]}])])}],
      kubernetes_use_cached_resources: true
    )

    assert_received {:connect, :"worker@10.0.0.1"}
    assert_request(%{"labelSelector" => @selector, "limit" => "500", "resourceVersion" => "0"})
    assert_request(%{"labelSelector" => @selector, "limit" => "500", "continue" => "next"})
  end

  test "applies readiness defaults and excludes terminating peers even when ready", context do
    endpoints = [
      %{"addresses" => ["10.0.0.1"], "conditions" => %{"ready" => true}},
      %{"addresses" => ["10.0.0.2"], "conditions" => %{"ready" => nil, "terminating" => nil}},
      %{"addresses" => ["10.0.0.3"]},
      %{"addresses" => ["10.0.0.4"], "conditions" => nil},
      %{"addresses" => ["10.0.0.5"], "conditions" => %{"ready" => false}},
      %{"addresses" => ["10.0.0.6"], "conditions" => %{"ready" => true, "terminating" => true}},
      %{"addresses" => ["10.0.0.7"], "conditions" => %{"ready" => false, "serving" => true}},
      %{"addresses" => ["10.0.0.8"], "conditions" => %{"ready" => true, "serving" => false}}
    ]

    start_strategy(context, [{200, page([slice("IPv4", endpoints)])}])
    assert_received {:connect, :"worker@10.0.0.1"}
    assert_received {:connect, :"worker@10.0.0.2"}
    assert_received {:connect, :"worker@10.0.0.3"}
    assert_received {:connect, :"worker@10.0.0.4"}
    assert_received {:connect, :"worker@10.0.0.8"}
    refute_received {:connect, _}
  end

  test "skips unsupported families and invalid addresses without dropping healthy neighbors",
       context do
    items = [
      slice("FQDN", [%{"addresses" => ["external.example"]}]),
      slice("other", [%{"addresses" => ["10.0.0.9"]}]),
      slice("IPv4", [%{"addresses" => [nil, "", "bad-address", "2001:db8::1", "10.0.0.1"]}]),
      slice("IPv6", [%{"addresses" => ["10.0.0.2", "2001:db8::2"]}])
    ]

    start_strategy(context, [{200, page(items)}])
    assert_received {:connect, :"worker@10.0.0.1"}
    assert_received {:connect, :"worker@2001:db8::2"}
    refute_received {:connect, _}
  end

  test "formats service hostnames using slice namespace and optional endpoint hostname",
       context do
    item =
      slice("IPv4", [
        %{
          "addresses" => ["10.0.0.1", "10.0.0.2"],
          "hostname" => "peer-0",
          "targetRef" => %{"namespace" => "other-namespace"}
        },
        %{"addresses" => ["10.0.0.3"]}
      ])

    item = put_in(item, ["metadata", "namespace"], "slice-namespace")

    start_strategy(context, [{200, page([item])}],
      mode: :hostname,
      kubernetes_service_name: "myservice",
      kubernetes_cluster_name: "custom"
    )

    assert_received {:connect, :"worker@peer-0.myservice.slice-namespace.svc.custom.local"}
    refute_received {:connect, _}
  end

  test "uses the requested namespace when a slice has no namespace metadata", context do
    item =
      slice("IPv4", [%{"addresses" => ["10.0.0.1"], "hostname" => "peer-0"}])
      |> Map.delete("metadata")

    start_strategy(context, [{200, page([item])}],
      mode: :hostname,
      kubernetes_service_name: "myservice"
    )

    assert_received {:connect, :"worker@peer-0.myservice.test.svc.cluster.local"}
  end

  test "formats IPv4 and IPv6 IP-based pod DNS names", context do
    start_strategy(
      context,
      [
        {200,
         page([
           slice("IPv4", [%{"addresses" => ["10.0.0.1"]}]),
           slice("IPv6", [%{"addresses" => ["2001:db8::1"]}])
         ])}
      ],
      mode: :dns
    )

    assert_received {:connect, :"worker@10-0-0-1.test.pod.cluster.local"}
    assert_received {:connect, :"worker@2001-db8--1.test.pod.cluster.local"}
  end

  for code <- [403, 500, 410] do
    test "discards a partial snapshot on HTTP #{code} and starts fresh next poll", context do
      responses = [
        {200, page([slice("IPv4", [%{"addresses" => ["10.0.0.2"]}])], "next")},
        {unquote(code), %{"kind" => "Status", "message" => "fixture failure"}}
      ]

      server = start_strategy(context, responses, [], [:"worker@10.0.0.1"])
      assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.1"]
      refute_received {:connect, _}
      refute_received {:disconnect, _}
      assert_request(%{"labelSelector" => @selector, "limit" => "500"})
      assert_request(%{"labelSelector" => @selector, "limit" => "500", "continue" => "next"})
      refute_received {:tls_request, _}

      set_responses(context, [{200, page([slice("IPv4", [%{"addresses" => ["10.0.0.2"]}])])}])
      send(server, :load)
      :sys.get_state(server)
      assert_received {:disconnect, :"worker@10.0.0.1"}
      assert_received {:connect, :"worker@10.0.0.2"}
      assert_request(%{"labelSelector" => @selector, "limit" => "500"})
    end
  end

  for {description, body} <- [
        {"invalid JSON", "{"},
        {"missing items", %{"metadata" => %{}}},
        {"non-list items", %{"items" => nil}},
        {"invalid metadata", %{"items" => [], "metadata" => "invalid"}},
        {"invalid continuation", %{"items" => [], "metadata" => %{"continue" => 1}}},
        {"invalid slice", %{"items" => ["invalid"]}},
        {"invalid endpoint list",
         %{"items" => [%{"addressType" => "IPv4", "endpoints" => "invalid"}]}},
        {"invalid addresses",
         %{"items" => [%{"addressType" => "IPv4", "endpoints" => [%{"addresses" => nil}]}]}},
        {"invalid conditions",
         %{
           "items" => [
             %{
               "addressType" => "IPv4",
               "endpoints" => [%{"addresses" => ["10.0.0.2"], "conditions" => "invalid"}]
             }
           ]
         }}
      ] do
    test "preserves membership on #{description}", context do
      start_strategy(context, [{200, unquote(Macro.escape(body))}], [], [:"worker@10.0.0.1"])
      assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.1"]
      refute_received {:connect, _}
      refute_received {:disconnect, _}
    end
  end

  test "rejects a repeated continuation token without applying a partial snapshot", context do
    duplicate = {200, page([slice("IPv4", [%{"addresses" => ["10.0.0.2"]}])], "loop")}
    start_strategy(context, [duplicate, duplicate], [], [:"worker@10.0.0.1"])
    assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.1"]
    refute_received {:connect, _}
    refute_received {:disconnect, _}
    assert_request(%{"labelSelector" => @selector, "limit" => "500"})
    assert_request(%{"labelSelector" => @selector, "limit" => "500", "continue" => "loop"})
    refute_received {:tls_request, _}
  end

  test "removes previous members after a successful empty snapshot", context do
    start_strategy(context, [{200, page([])}], [], [:"worker@10.0.0.1"])
    assert_received {:disconnect, :"worker@10.0.0.1"}
    assert ConnectedNodes.list_nodes(context.nodes) == []
  end

  for {description, item} <- [
        {"null", %{"addressType" => "IPv4", "endpoints" => nil}},
        {"omitted", %{"addressType" => "IPv4"}}
      ] do
    test "treats #{description} endpoints in a placeholder slice as an empty membership",
         context do
      start_strategy(context, [{200, page([unquote(Macro.escape(item))])}], [], [
        :"worker@10.0.0.1"
      ])

      assert_received {:disconnect, :"worker@10.0.0.1"}
      assert ConnectedNodes.list_nodes(context.nodes) == []
    end
  end

  test "uses the explicit selector independently of the hostname service option", context do
    selector = "kubernetes.io/service-name in (myapp,other),team=apps"

    start_strategy(context, [{200, page([slice("IPv4", [%{"addresses" => ["10.0.0.1"]}])])}],
      kubernetes_selector: selector,
      kubernetes_service_name: "formatting-only"
    )

    assert_received {:connect, :"worker@10.0.0.1"}
    assert_request(%{"labelSelector" => selector, "limit" => "500"})
  end

  test "retains members without sending a bearer token when the CA is missing", context do
    File.rm!(Path.join(context.directory, "ca.crt"))
    start_strategy(context, [{200, page([])}], [], [:"worker@10.0.0.1"])
    assert ConnectedNodes.list_nodes(context.nodes) == [:"worker@10.0.0.1"]
    refute_received {:disconnect, _}
    refute_received {:tls_request, _}
  end

  defp slice(family, endpoints) do
    %{"addressType" => family, "metadata" => %{"namespace" => "test"}, "endpoints" => endpoints}
  end

  defp page(items, continuation \\ "") do
    %{
      "kind" => "EndpointSliceList",
      "apiVersion" => "discovery.k8s.io/v1",
      "metadata" => %{"continue" => continuation},
      "items" => items
    }
  end

  defp start_strategy(context, responses, config \\ [], known \\ []) do
    set_responses(context, responses)
    ConnectedNodes.set_connected(context.nodes, known)

    state = %{
      context.state
      | meta: MapSet.new(known),
        config: Keyword.merge(context.state.config, config)
    }

    start_supervised!({Kubernetes, [state]})
  end

  defp set_responses(context, responses),
    do: Agent.update(context.responses, fn _ -> responses end)

  defp assert_request(query) do
    assert_received {:tls_request, request}
    ["GET", target, "HTTP/1.1" | _] = String.split(request, [" ", "\r\n"])
    uri = URI.parse(target)
    assert uri.path == @path
    assert URI.decode_query(uri.query) == query
    request
  end
end
