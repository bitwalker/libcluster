defmodule Cluster.Strategy.KubernetesDNSTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Cluster.Strategy.Kubernetes.DNS
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
              service: "app",
              application_name: "node",
              resolver: fn _query ->
                {:ok, {:hostent, 'app', [], :inet, 4, [{10, 0, 0, 1}, {10, 0, 0, 2}]}}
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DNS.start_link()

        assert_receive {:connect, :"node@10.0.0.1"}, 100
        assert_receive {:connect, :"node@10.0.0.2"}, 100
      end)
    end

    test "removes nodes" do
      capture_log(fn ->
        [
          %State{
            topology: :k8s_dns_example,
            config: [
              polling_interval: 100,
              service: "app",
              application_name: "node",
              resolver: fn _query -> {:ok, {:hostent, 'app', [], :inet, 4, [{10, 0, 0, 1}]}} end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[:"node@10.0.0.1", :"node@10.0.0.2"]]},
            meta: MapSet.new([:"node@10.0.0.1", :"node@10.0.0.2"])
          }
        ]
        |> DNS.start_link()

        assert_receive {:disconnect, :"node@10.0.0.2"}, 100
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
              application_name: "node",
              resolver: fn _query -> {:ok, {:hostent, 'app', [], :inet, 4, [{10, 0, 0, 1}]}} end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[:"node@10.0.0.1"]]},
            meta: MapSet.new([:"node@10.0.0.1"])
          }
        ]
        |> DNS.start_link()

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
              application_name: "node",
              resolver: fn _query -> {:error, :nxdomain} end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DNS.start_link()

        refute_receive {:connect, _}, 100
      end)
    end
  end

  describe "KubernetesDNS configs" do
    test "allow custom node naming" do
      node_naming = fn app_name, ip ->
        :"#{app_name}@#{String.replace(ip, ".", "-")}.default.pod.cluster.local"
      end

      capture_log(fn ->
        [%State{
          topology: :k8s_dns_example,
          config: [
            polling_interval: 100,
            service: "app",
            application_name: "node",
            node_naming: node_naming,
            resolver: fn _query ->
              {:ok, {:hostent, 'app', [], :inet, 4, [{10, 0, 0, 1}, {10, 0, 0, 2}]}}
            end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[]]}
        }]
        |> DNS.start_link()

        assert_receive {:connect, :"node@10-0-0-1.default.pod.cluster.local"}, 100
        assert_receive {:connect, :"node@10-0-0-2.default.pod.cluster.local"}, 100
      end)
    end

    def dummy_node_naming(app_name, ip, arg1, arg2) do
      :"#{app_name}@#{arg1}.#{arg2}.#{ip}"
    end

    test "allow node naming as [module, function, [args]]" do
      capture_log(fn ->
        [%State{
          topology: :k8s_dns_example,
          config: [
            polling_interval: 100,
            service: "app",
            application_name: "node",
            node_naming: [__MODULE__, :dummy_node_naming, ['extra', 'args']],
            resolver: fn _query ->
              {:ok, {:hostent, 'app', [], :inet, 4, [{10, 0, 0, 1}, {10, 0, 0, 2}]}}
            end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[]]}
        }]
        |> DNS.start_link()

        assert_receive {:connect, :"node@extra.args.10.0.0.1"}, 100
        assert_receive {:connect, :"node@extra.args.10.0.0.2"}, 100
      end)
    end
  end
end
