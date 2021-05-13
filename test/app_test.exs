defmodule Cluster.AppTest do
  @moduledoc false

  use ExUnit.Case

  defmodule TestStrategy do
    @moduledoc false
    use Cluster.Strategy

    def start_link([%Cluster.Strategy.State{config: config} = state]) do
      config
      |> Keyword.fetch!(:caller)
      |> send({:opts, state})

      :ignore
    end
  end

  describe "start/2" do
    test "calls strategy with right arguments" do
      Cluster.Supervisor.start_link([
        [
          test: [
            strategy: TestStrategy,
            config: [
              caller: self()
            ]
          ]
        ]
      ])

      assert_receive {:opts, state}
      assert :test == state.topology
      assert {:net_kernel, :connect_node, []} = state.connect
      assert {:erlang, :disconnect_node, []} = state.disconnect
      assert {:erlang, :nodes, [:connected]} = state.list_nodes
      assert [caller: _] = state.config
    end
  end
end
