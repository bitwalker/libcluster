defmodule Cluster.Strategy.LocalEpmd do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol.

  Unlike Cluster.Strategy.Empd, this strategy assumes that all nodes are on
  the local host and can be discovered by epmd.

  It should be configured as follows:

      config :libcluster,
        topologies: [
          local_epmd_example: [
            strategy: #{__MODULE__}]]

  """
  use Cluster.Strategy

  alias Cluster.Strategy.State

  def start_link([%State{} = state]) do
    nodes = discover_nodes()

    Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
    :ignore
  end

  defp discover_nodes do
    suffix = get_host_suffix(Node.self())

    {:ok, names} = :erl_epmd.names()
    for {n, _} <- names, do: List.to_atom(n ++ suffix)
  end

  defp get_host_suffix(self) do
    self = Atom.to_charlist(self)
    [_, suffix] = :string.split(self, '@')
    '@' ++ suffix
  end
end
