defmodule Cluster.StrategyTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy
  alias Cluster.Nodes

  require Cluster.Nodes

  import ExUnit.CaptureLog

  describe "connect_nodes/4" do
    test "does not connect existing nodes again" do
      connect = {Nodes, :connect, [self()]}
      list_nodes = {Nodes, :list_nodes, [[Node.self()]]}

      assert :ok = Strategy.connect_nodes(__MODULE__, connect, list_nodes, [Node.self()])

      refute_receive {:connect, _}
    end

    test "does connect new nodes" do
      connect = {Nodes, :connect, [self()]}
      list_nodes = {Nodes, :list_nodes, [[Node.self()]]}

      assert capture_log(fn ->
               assert :ok =
                        Strategy.connect_nodes(__MODULE__, connect, list_nodes, [:"foo@some.host"])
             end) =~ "connected to :\"foo@some.host\""

      assert_receive {:connect, :"foo@some.host"}
    end

    test "handles connect failure" do
      connect = {Nodes, :connect, [self(), false]}
      list_nodes = {Nodes, :list_nodes, [[Node.self()]]}

      assert capture_log(fn ->
               assert {:error, ["foo@some.host": false]} =
                        Strategy.connect_nodes(__MODULE__, connect, list_nodes, [:"foo@some.host"])
             end) =~ "unable to connect to :\"foo@some.host\""

      assert_receive {:connect, :"foo@some.host"}
    end

    test "handles connect ignore" do
      connect = {Nodes, :connect, [self(), :ignored]}
      list_nodes = {Nodes, :list_nodes, [[Node.self()]]}

      assert capture_log(fn ->
               assert {:error, ["foo@some.host": :ignored]} =
                        Strategy.connect_nodes(__MODULE__, connect, list_nodes, [:"foo@some.host"])
             end) =~ "unable to connect to :\"foo@some.host\""

      assert_receive {:connect, :"foo@some.host"}
    end
  end

  describe "disconnect_nodes/4" do
    test "does not disconnect missing noded" do
      disconnect = {Nodes, :disconnect, [self()]}
      list_nodes = {Nodes, :list_nodes, [[]]}

      assert :ok = Strategy.disconnect_nodes(__MODULE__, disconnect, list_nodes, [Node.self()])

      refute_receive {:disconnect, _}
    end

    test "does disconnect new nodes" do
      disconnect = {Nodes, :disconnect, [self()]}
      list_nodes = {Nodes, :list_nodes, [[:"foo@some.host"]]}

      assert capture_log(fn ->
               assert :ok =
                        Strategy.disconnect_nodes(__MODULE__, disconnect, list_nodes, [
                          :"foo@some.host"
                        ])
             end) =~ "disconnected from :\"foo@some.host\""

      assert_receive {:disconnect, :"foo@some.host"}
    end

    test "handles disconnect error" do
      disconnect = {Nodes, :disconnect, [self(), :failed]}
      list_nodes = {Nodes, :list_nodes, [[:"foo@some.host"]]}

      assert capture_log(fn ->
               assert {:error, ["foo@some.host": :failed]} =
                        Strategy.disconnect_nodes(__MODULE__, disconnect, list_nodes, [
                          :"foo@some.host"
                        ])
             end) =~
               "disconnect from :\"foo@some.host\" failed with: :failed"

      assert_receive {:disconnect, :"foo@some.host"}
    end
  end
end
