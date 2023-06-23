defmodule Cluster.Strategy.DNSPoll do
  @moduledoc """
  Assumes you have nodes that respond to the specified DNS query (A record), and which follow the node name pattern of
  `<name>@<ip-address>`. If your setup matches those assumptions, this strategy will periodically poll DNS and connect
  all nodes it finds.

  ## Options

  * `poll_interval` - How often to poll in milliseconds (optional; default: 5_000)
  * `query` - DNS query to use (required; e.g. "my-app.example.com")
  * `node_basename` - The short name of the nodes you wish to connect to (required; e.g. "my-app")
  * `prune` - Remove nodes not returned in DNS response (optional; default: true)

  ## Usage

      config :libcluster,
        topologies: [
          dns_poll_example: [
            strategy: #{__MODULE__},
            config: [
              polling_interval: 5_000,
              query: "my-app.example.com",
              node_basename: "my-app",
              prune: true]]]
  """

  use GenServer
  import Cluster.Logger

  alias Cluster.Strategy.State
  alias Cluster.Strategy

  @default_polling_interval 5_000
  @default_prune true

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{meta: nil} = state]) do
    init([%State{state | :meta => MapSet.new()}])
  end

  def init([%State{} = state]) do
    {:ok, do_poll(state)}
  end

  @impl true
  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, state), do: {:noreply, do_poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp do_poll(
         %State{
           topology: topology,
           connect: connect,
           list_nodes: list_nodes
         } = state
       ) do
    new_nodelist = state |> get_nodes() |> MapSet.new()

    new_nodelist = if prune?(state), do: prune_nodelist(state, new_nodelist), else: new_nodelist

    new_nodelist =
      case Strategy.connect_nodes(
             topology,
             connect,
             list_nodes,
             MapSet.to_list(new_nodelist)
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

  defp prune?(%{config: config}) do
    Keyword.get(config, :prune, @default_prune)
  end

  defp prune_nodelist(
         %State{
           topology: topology,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state,
         new_nodelist
       ) do
    removed = MapSet.difference(state.meta, new_nodelist)

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
  end

  defp get_nodes(%State{config: config} = state) do
    query = Keyword.fetch(config, :query)
    node_basename = Keyword.fetch(config, :node_basename)

    resolver =
      Keyword.get(config, :resolver, fn query ->
        query
        |> String.to_charlist()
        |> lookup_all_ips
      end)

    resolve(query, node_basename, resolver, state)
  end

  # query for all ips responding to a given dns query
  # format ips as node names
  # filter out me
  defp resolve({:ok, query}, {:ok, node_basename}, resolver, %State{topology: topology})
       when is_binary(query) and is_binary(node_basename) and query != "" and node_basename != "" do
    debug(topology, "polling dns for '#{query}'")
    me = node()

    query
    |> resolver.()
    |> Enum.map(&format_node(&1, node_basename))
    |> Enum.reject(fn n -> n == me end)
  end

  defp resolve({:ok, invalid_query}, {:ok, invalid_basename}, _resolver, %State{
         topology: topology
       }) do
    warn(
      topology,
      "dns polling strategy is selected, but query or basename param is invalid: #{inspect(%{query: invalid_query, node_basename: invalid_basename})}"
    )

    []
  end

  defp resolve(:error, :error, _resolver, %State{topology: topology}) do
    warn(
      topology,
      "dns polling strategy is selected, but query and basename params missed"
    )

    []
  end

  def lookup_all_ips(q) do
    Enum.flat_map([:a, :aaaa], fn t -> :inet_res.lookup(q, :in, t) end)
  end

  # turn an ip into a node name atom, assuming that all other node names looks similar to our own name
  defp format_node(ip, base_name), do: :"#{base_name}@#{:inet_parse.ntoa(ip)}"
end
