defmodule Cluster.Strategy.Epmd do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol.

  You can have libcluster automatically connect nodes on startup for you by configuring
  the strategy like below:

      config :libcluster,
        topologies: [
          epmd_example: [
            strategy: #{__MODULE__},
            config: [
              hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]]]]

  """
  use Cluster.Strategy

  alias Cluster.Strategy.State

  def start_link([%State{config: config} = state]) do
    case Keyword.get(config, :hosts, []) do
      [] ->
        :ignore

      nodes when is_list(nodes) ->
        Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
        :ignore
    end
  end
end
