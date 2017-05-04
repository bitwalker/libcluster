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

  def start_link(opts) do
    topology = Keyword.fetch!(opts, :topology)
    config   = Keyword.get(opts, :config, [])
    connect  = Keyword.fetch!(opts, :connect)
    list_nodes = Keyword.fetch!(opts, :list_nodes)
    case Keyword.get(config, :hosts, []) do
      [] ->
        :ignore
      nodes when is_list(nodes) ->
        Cluster.Strategy.connect_nodes(topology, connect, list_nodes, nodes)
        :ignore
    end
  end
end
