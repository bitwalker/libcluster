defmodule Cluster.Strategy.ErlangHosts do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol by
  using a .hosts.erlang file (as used by the :net_adm module)

  Please see http://erlang.org/doc/man/net_adm.html for more details.

  You can have libcluster automatically connect nodes on startup for you by configuring
  the strategy like below:

  An optional timeout can be specified in the config. This is the timeout that
  will be used in the GenServer to connect the nodes. This defaults to
  `:infinity` meaning that the connection process will only happen when the
  worker is started. Any integer timeout will result in the connection process
  being triggered. In the example below, it has been configured for 30 seconds.

  config :libcluster,
    topologies: [
      erlang_hosts_example: [
        strategy: #{__MODULE__},
        config: [timeout: 30_000]]]
  """
  use Cluster.Strategy

  def start_link(opts) do
    case :net_adm.host_file() do
      {:error, _} ->
        topology = Keyword.fetch!(opts, :topology)
        Cluster.Logger.warn(topology, "couldn't find .hosts.erlang file - not joining cluster")
        :ignore
      file ->
        GenServer.start_link(__MODULE__, {opts, file})
    end
  end

  def init({opts, hosts_file}) do
    state = connect_hosts(%{opts: opts, hosts_file: hosts_file})
    {:ok, state, configured_timeout(state)}
  end

  def handle_info(:timeout, state), do: handle_info(:connect, state)
  def handle_info(:connect, state) do
    new_state = connect_hosts(state)
    {:noreply, new_state, configured_timeout(new_state)}
  end

  defp configured_timeout(%{opts: opts}) do
    get_in(opts, [:config, :timeout]) || :infinity
  end

  defp connect_hosts(%{opts: opts, hosts_file: hosts_file} = state) do
    topology = Keyword.fetch!(opts, :topology)
    connect  = Keyword.fetch!(opts, :connect)
    list_nodes = Keyword.fetch!(opts, :list_nodes)

    nodes =
      hosts_file
      |> Enum.map(&{:net_adm.names(&1), &1})
      |> gather_node_names([])
      |> List.delete(node())

    Cluster.Strategy.connect_nodes(topology, connect, list_nodes, nodes)
    state
  end

  defp gather_node_names([], acc), do: acc
  defp gather_node_names([{{:ok, names}, host} | rest], acc) do
    names = Enum.map(names, fn {name, _} -> String.to_atom("#{name}@#{host}") end)
    gather_node_names(rest, names ++ acc)
  end
  defp gather_node_names([_ | rest], acc), do: gather_node_names(rest, acc)
end
