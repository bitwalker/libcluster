defmodule Cluster.Strategy.DNSPoll do
  @moduledoc """
  Assumes you have nodes that respond to the specified DNS query (A record), and which follow the node name pattern of
  `<name>@<ip-address>`. If your setup matches those assumptions, this strategy will periodically poll DNS and connect
  all nodes it finds.

  ## Options

  * `poll_interval` - How often to poll in milliseconds (optional; default: 5_000)
  * `query` - DNS query to use (required; e.g. "my-app.example.com")
  * `node_basename` - The short name of the nodes you wish to connect to (required; e.g. "my-app")

  ## Usage

      config :libcluster,
        topologies: [
          dns_poll_example: [
            strategy: #{__MODULE__},
            config: [
              poll_interval: 5_000,
              query: "my-app.example.com",
              node_basename: "my-app"]]]
  """

  use GenServer
  # use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State
  alias Cluster.Strategy

  @default_poll_interval 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # setup initial state
  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.get(opts, :config, [])
    }

    query = Keyword.fetch!(state.config, :query)
    node_basename = Keyword.fetch!(state.config, :node_basename)
    poll_interval = Keyword.get(state.config, :poll_interval, @default_poll_interval)

    state = %{state | meta: {poll_interval, query, node_basename}}

    info(state.topology, "starting dns polling for #{query}")

    {:ok, do_poll(state)}
  end

  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, state), do: {:noreply, do_poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp do_poll(%State{meta: {poll_interval, query, node_basename}} = state) do
    nodes = get_nodes(state.topology, query, node_basename)

    nodes =
      case Strategy.connect_nodes(
             state.topology,
             state.connect,
             state.list_nodes,
             nodes
           ) do
        :ok ->
          nodes

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, nodes |> MapSet.new(), fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    # reschedule a call to itself in poll_interval ms
    Process.send_after(self(), :poll, poll_interval)

    %{state | meta: {poll_interval, query, node_basename, nodes}}
  end

  defp do_poll(%State{meta: {poll_interval, query, node_basename, nodes}} = state) do
    new_nodelist = state.topology |> get_nodes(query, node_basename) |> MapSet.new()

    nodes = nodes |> MapSet.new()
    added = MapSet.difference(new_nodelist, nodes)
    removed = MapSet.difference(nodes, new_nodelist)

    debug(state.topology, "nodes cur: #{inspect(nodes)}")
    debug(state.topology, "nodes add: #{inspect(added)}")
    debug(state.topology, "nodes rem: #{inspect(removed)}")

    new_nodelist =
      case Strategy.disconnect_nodes(
             state.topology,
             state.disconnect,
             state.list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      case Strategy.connect_nodes(
             state.topology,
             state.connect,
             state.list_nodes,
             MapSet.to_list(added)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    Process.send_after(self(), :poll, poll_interval)

    %{state | meta: {poll_interval, query, node_basename, new_nodelist}}
  end

  # query for all ips responding to a given dns query
  # format ips as node names
  # filter out me
  defp get_nodes(topology, query, node_basename) do
    debug(topology, "polling dns for #{query}")
    me = node()

    new_nodes =
      query
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :a)
      |> Enum.map(&format_node(&1, node_basename))
      |> Enum.reject(fn n -> n == me end)

    debug(topology, "found nodes #{inspect(new_nodes)}")

    new_nodes
  end

  # turn an ip into a node name atom, assuming that all other node names looks similar to our own name
  defp format_node({a, b, c, d}, sname), do: :"#{sname}@#{a}.#{b}.#{c}.#{d}"
end
