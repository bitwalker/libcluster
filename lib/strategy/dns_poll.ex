defmodule Cluster.Strategy.DNSPoll do
  @moduledoc """
  Assumes you have nodes that respond to the specified DNS query (A record), and which follow the node name pattern of
  `<sname>@<ip-address>`. If your setup matches those assumptions, this strategy will periodically poll DNS and connect
  all nodes it finds.

  options:

  * `poll_interval` - How often to poll in milliseconds (optional; default: 5_000)
  * `query` - DNS query to use (required; e.g. "my-app.example.com")
  * `node_sname` - The short name of the nodes you wish to connect to (required; e.g. "my-app")

  example config:

      config :libcluster,
        topologies: [
          dns_poll_example: [
            strategy: #{__MODULE__},
            config: [
              poll_interval: 5_000,
              query: "my-app.example.com",
              node_sname: "my-app"]]]
  """

  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

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
    node_sname = Keyword.fetch!(state.config, :node_sname)
    poll_interval = Keyword.get(state.config, :poll_interval, @default_poll_interval)

    state = %{state | meta: {poll_interval, query, node_sname}}

    info(state.topology, "starting dns polling for #{query}")

    {:ok, do_poll(state)}
  end

  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, state), do: {:noreply, do_poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp do_poll(%State{meta: {poll_interval, query, node_sname}} = state) do
    debug(state.topology, "polling dns for #{query}")

    me = node()

    # query for all ips responding to a given dns query
    # format ips as node names
    # filter out me
    nodes =
      query
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :a)
      |> Enum.map(&format_node(&1, node_sname))
      |> Enum.reject(fn n -> n == me end)

    debug(state.topology, "found nodes #{inspect(nodes)}")

    Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)

    # reschedule a call to itself in poll_interval ms
    Process.send_after(self(), :poll, poll_interval)

    %{state | meta: {poll_interval, query, node_sname, nodes}}
  end

  # turn an ip into a node name atom, assuming that all other node names looks similar to our own name
  defp format_node({a, b, c, d}, sname), do: :"#{sname}@#{a}.#{b}.#{c}.#{d}"
end
