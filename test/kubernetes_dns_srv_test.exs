defmodule Cluster.Strategy.KubernetesSRVDNSTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Cluster.Strategy.Kubernetes.DNS, as: DNSSRV
  alias Cluster.Strategy.State
  alias Cluster.Nodes

  require Cluster.Nodes

  describe "start_link/1" do
    test "adds new nodes" do
      capture_log(fn ->
        [
          %State{
            topology: :k8s_dns_example,
            config: [
              polling_interval: 100,
              service: "elixir-plug-poc",
              namespace: "default",
              application_name: "node",
              method: :srv,
              resolver: fn _query ->
                {:ok,
                 {:hostent, 'elixir-plug-poc.default.svc.cluster.local', [], :srv, 2,
                  [
                    {10, 50, 0, 'elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local'},
                    {10, 50, 0, 'elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local'}
                  ]}}
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DNSSRV.start_link()

        assert_receive {:connect,
                        :"node@elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local"},
                       100

        assert_receive {:connect,
                        :"node@elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local"},
                       100
      end)
    end

    test "removes nodes" do
      capture_log(fn ->
        [
          %State{
            topology: :k8s_dns_example,
            config: [
              polling_interval: 100,
              service: "elixir-plug-poc",
              namespace: "default",
              application_name: "node",
              method: :srv,
              resolver: fn _query ->
                {:ok,
                 {:hostent, 'elixir-plug-poc.default.svc.cluster.local', [], :srv, 1,
                  [
                    {10, 50, 0, 'elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local'}
                  ]}}
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes:
              {Nodes, :list_nodes,
               [
                 [
                   :"node@elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local",
                   :"node@elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local"
                 ]
               ]},
            meta:
              MapSet.new([
                :"node@elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local",
                :"node@elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local"
              ])
          }
        ]
        |> DNSSRV.start_link()

        assert_receive {:disconnect,
                        :"node@elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local"},
                       100
      end)
    end

    test "keeps state" do
      capture_log(fn ->
        [
          %State{
            topology: :k8s_dns_example,
            config: [
              polling_interval: 100,
              service: "app",
              namespace: "default",
              application_name: "node",
              method: :srv,
              resolver: fn _query ->
                {:ok,
                 {:hostent, 'elixir-plug-poc.default.svc.cluster.local', [], :srv, 2,
                  [
                    {10, 50, 0, 'elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local'}
                  ]}}
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes:
              {Nodes, :list_nodes,
               [[:"node@elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local"]]},
            meta:
              MapSet.new([:"node@elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local"])
          }
        ]
        |> DNSSRV.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)
    end

    test "does not connect to anything if name is not resolved" do
      capture_log(fn ->
        [
          %State{
            topology: :k8s_dns_example,
            config: [
              polling_interval: 100,
              service: "app",
              namespace: "default",
              application_name: "node",
              method: :srv,
              resolver: fn _query -> {:error, :nxdomain} end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DNSSRV.start_link()

        refute_receive {:connect, _}, 100
      end)
    end
  end
end
