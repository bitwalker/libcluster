defmodule Cluster.Strategy.ErlangHosts do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol by
  using a .hosts.erlang file (as used by the :net_adm module)

  Please see http://erlang.org/doc/man/net_adm.html for more details.

  You can have libcluster automatically connect nodes on startup for you by configuring
  the strategy like below:

  config :libcluster,
    topologies: [
      erlang_hosts_example: [
        strategy: #{__MODULE__}]]
  """
  use Cluster.Strategy

  def start_link(opts) do
    topology = Keyword.fetch!(opts, :topology)
    connect  = Keyword.fetch!(opts, :connect)
    list_nodes = Keyword.fetch!(opts, :list_nodes)

    case :net_adm.host_file() do
      {:error, _} ->
        Cluster.Logger.warn(topology, "couldn't find .hosts.erlang file - not joining cluster")
        :ignore
      file ->
      nodes =
        file
        |> Enum.map(&{:net_adm.names(&1), &1})
        |> gather_node_names([])

      Cluster.Strategy.connect_nodes(topology, connect, list_nodes, nodes)
      :ignore
    end
  end

  defp gather_node_names([], acc) do
    acc
  end

  defp gather_node_names([{{:ok, names}, host} | rest], acc) do
    names = Enum.map(names, fn {name, _} -> String.to_atom("#{name}@#{host}") end)
    gather_node_names(rest, names ++ acc)
  end

  defp gather_node_names([_ | rest], acc) do
    gather_node_names(rest, acc)
  end
end
