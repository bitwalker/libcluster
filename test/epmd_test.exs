defmodule Cluster.Strategy.EpmdTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy.Epmd

  require Cluster.Nodes

  describe "start_link/1" do
    @tag capture_log: true
    test "starts GenServer and connects nodes" do
      {:ok, pid} =
        Epmd.start_link([
          %Cluster.Strategy.State{
            topology: :name,
            config: [hosts: [:foo@bar]],
            connect: {Cluster.Nodes, :connect, [self()]},
            list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
          }
        ])

      assert is_pid(pid)

      assert_receive {:connect, :foo@bar}, 5_000
    end

    @tag capture_log: true
    test "reconnects every time the configured timeout was reached" do
      timeout = 500
      start_timestamp = NaiveDateTime.utc_now()

      {:ok, _pid} =
        Epmd.start_link([
          %Cluster.Strategy.State{
            topology: :name,
            config: [hosts: [:foo@bar], timeout: timeout],
            connect: {Cluster.Nodes, :connect, [self()]},
            list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
          }
        ])

      # Initial connect
      assert_receive {:connect, :foo@bar}, 5_000

      # First reconnect should not have happened right away,
      # but it should happen after a timeout
      refute_received {:connect, _}
      assert_receive {:connect, :foo@bar}, 2 * timeout

      # A consecutive reconnect should not have happened right away,
      # but it should happen after a timeout
      refute_received {:connect, _}
      assert_receive {:connect, :foo@bar}, 2 * timeout

      duration = NaiveDateTime.diff(NaiveDateTime.utc_now(), start_timestamp, :millisecond)
      assert duration > 2 * timeout
    end
  end
end
