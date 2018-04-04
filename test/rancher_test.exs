defmodule Cluster.Strategy.RancherTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  alias Plug.Conn
  alias Cluster.Nodes
  alias Cluster.Strategy.Rancher
  alias Cluster.Fixtures.RancherResponse, as: RancherFixture

  describe "start_link/1" do
    test "adds new nodes with self config", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/latest/self/service", fn conn ->
        Conn.resp(conn, 200, RancherFixture.batch_response(["10.0.0.1", "10.0.0.2"]))
      end)

      capture_log(fn ->
        bypass.port |> endpoint_url() |> valid_opts(:stacks) |> Rancher.start_link()

        assert_receive {:connect, :"node@10.0.0.1"}, 100
        assert_receive {:connect, :"node@10.0.0.2"}, 100
      end)
    end

    test "adds new nodes with multi-stacks config", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/latest/stacks/api/services/app", fn conn ->
        Conn.resp(conn, 200, RancherFixture.batch_response(["10.0.0.1", "10.0.0.2"]))
      end)

      capture_log(fn ->
        bypass.port |> endpoint_url() |> valid_opts() |> Rancher.start_link()

        assert_receive {:connect, :"node@10.0.0.1"}, 100
        assert_receive {:connect, :"node@10.0.0.2"}, 100
      end)
    end

    test "removes nodes", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/latest/stacks/api/services/app", fn conn ->
        Conn.resp(conn, 200, RancherFixture.service_response("10.0.0.1"))
      end)

      capture_log(fn ->
        bypass.port
        |> endpoint_url()
        |> valid_opts()
        |> put_in(
          [:list_nodes],
          {Nodes, :list_nodes, [[:"node@10.0.0.1", :"node@10.0.0.2"]]}
        )
        |> put_in([:meta], MapSet.new([:"node@10.0.0.1", :"node@10.0.0.2"]))
        |> Rancher.start_link()

        assert_receive {:disconnect, :"node@10.0.0.2"}, 100
      end)
    end

    test "keeps state", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/latest/stacks/api/services/app", fn conn ->
        Conn.resp(conn, 200, RancherFixture.service_response("10.0.0.1"))
      end)

      capture_log(fn ->
        bypass.port
        |> endpoint_url()
        |> valid_opts()
        |> put_in(
          [:list_nodes],
          {Nodes, :list_nodes, [[:"node@10.0.0.1"]]}
        )
        |> put_in([:meta], MapSet.new([:"node@10.0.0.1"]))
        |> Rancher.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)
    end

    test "keeps state if rancher response fails", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/latest/stacks/api/services/app", fn conn ->
        Conn.resp(conn, 500, "")
      end)

      capture_log(fn ->
        bypass.port
        |> endpoint_url()
        |> valid_opts()
        |> Rancher.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)
    end

    test "keeps state if rancher does not respond" do
      capture_log(fn ->
        base_opts()
        |> put_in([:config, :node_basename], "node")
        |> put_in([:config, :stacks], [[name: "api", services: ["app"]]])
        |> Rancher.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)
    end

    test "fails to connect/disconnect", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/latest/stacks/api/services/app", fn conn ->
        Conn.resp(conn, 200, RancherFixture.service_response("10.0.0.1"))
      end)

      failed = fn ->
        bypass.port
        |> endpoint_url()
        |> valid_opts()
        |> put_in([:connect], {Nodes, :connect, [self(), false]})
        |> put_in([:disconnect], {Nodes, :disconnect, [self(), :failed]})
        |> put_in(
          [:list_nodes],
          {Nodes, :list_nodes, [[:"node@10.0.0.2"]]}
        )
        |> put_in([:meta], MapSet.new([:"node@10.0.0.2"]))
        |> Rancher.start_link()
      end

      assert capture_log(failed) =~ "unable to connect"
      assert capture_log(failed) =~ "disconnect from :\"node@10.0.0.2\" failed"
    end

    test "does not connect to anything with wrong config" do
      # missing stacks
      capture_log(fn ->
        base_opts()
        |> put_in([:config, :node_basename], "service")
        |> Rancher.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)

      # missing node_basename
      capture_log(fn ->
        base_opts()
        |> put_in([:config, :stacks], [[name: "foo"]])
        |> Rancher.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)

      # empty stacks & node_basename
      capture_log(fn ->
        base_opts()
        |> put_in([:config, :stacks], [])
        |> put_in([:config, :node_basename], "")
        |> Rancher.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)

      # missing stacks & node_basename
      capture_log(fn ->
        base_opts() |> Rancher.start_link()
        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)
    end
  end

  defp endpoint_url(port), do: "http://localhost:#{port}"

  defp base_opts do
    [
      topology: :multi_rancher,
      config: [polling_interval: 100],
      connect: {Nodes, :connect, [self()]},
      disconnect: {Nodes, :disconnect, [self()]},
      list_nodes: {Nodes, :list_nodes, [[]]}
    ]
  end

  def valid_opts(endpoint_url) do
    base_opts()
    |> put_in([:config, :node_basename], "node")
    |> put_in([:config, :stacks], [[name: "api", services: ["app"]]])
    |> put_in([:config, :rancher_metadata_base_url], endpoint_url)
  end

  def valid_opts(endpoint_url, :stacks) do
    base_opts()
    |> put_in([:config, :node_basename], "node")
    |> put_in([:config, :stacks], :self)
    |> put_in([:config, :rancher_metadata_base_url], endpoint_url)
  end
end
