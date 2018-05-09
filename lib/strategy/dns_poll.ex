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
              polling_interval: 5_000,
              query: "my-app.example.com",
              node_basename: "my-app"]]]
  """

  use GenServer
  import Cluster.Logger

  alias Cluster.Strategy.State
  alias Cluster.Strategy

  @default_polling_interval 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # setup initial state
  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.get(opts, :config, []),
      meta: Keyword.get(opts, :meta, MapSet.new([]))
    }

    {:ok, do_poll(state)}
  end

  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, state), do: {:noreply, do_poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp do_poll(
         %State{
           topology: topology,
           connect: connect,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state
       ) do
    new_nodelist = state |> get_nodes()
    added = MapSet.difference(new_nodelist, state.meta)
    removed = MapSet.difference(state.meta, new_nodelist)

    # IO.inspect("+++++++++++++++++++++++++++++++++++")
    # IO.inspect("nodes meta: #{inspect(state.meta)}")
    # IO.inspect("nodes discovered: #{inspect(new_nodelist)}")
    # IO.inspect("nodes to add: #{inspect(added)}")
    # IO.inspect("nodes to rem: #{inspect(removed)}")
    # IO.inspect("===================================")

    new_nodelist =
      case Strategy.disconnect_nodes(
             topology,
             disconnect,
             list_nodes,
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
             topology,
             connect,
             list_nodes,
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

    Process.send_after(self(), :poll, polling_interval(state))

    %{state | :meta => new_nodelist}
  end

  defp polling_interval(%{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  # query for all ips responding to a given dns query
  # format ips as node names
  # filter out me
  defp get_nodes(%State{config: config, topology: topology}) do
    resolver =
      Keyword.get(config, :resolver, fn query ->
        query
        |> String.to_charlist()
        |> :inet_res.lookup(:in, :a)
      end)

    # TODO check if config is correct
    query = Keyword.fetch!(config, :query)
    node_basename = Keyword.fetch!(config, :node_basename)

    debug(topology, "polling dns for '#{query}'")
    me = node()

    query
    |> resolver.()
    |> Enum.map(&format_node(&1, node_basename))
    |> Enum.reject(fn n -> n == me end)
    |> MapSet.new()
  end

  # defp resolve(query) do
  #   query
  #   |> String.to_charlist()
  #   |> :inet_res.lookup(:in, :a)
  # end

  # turn an ip into a node name atom, assuming that all other node names looks similar to our own name
  defp format_node({a, b, c, d}, base_name), do: :"#{base_name}@#{a}.#{b}.#{c}.#{d}"
end
