defmodule Cluster.Strategy.DNSPoll do
  @moduledoc """
  TODO: add description

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
      config: Keyword.fetch!(opts, :config)
    }
    query = Keyword.get(state.config, :query)
    poll_interval = Keyword.get(state.config, :poll_interval, @default_poll_interval)
    node_sname = Keyword.get(state.config, :node_sname)

    state = %{state | :meta => {poll_interval, query, node_sname}}
    {:ok, state, 0}
  end

  # timeout starts the loop by calling :poll
  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, %State{meta: {poll_interval, query, node_sname}} = state) do
    debug state.topology, "polling dns for #{query}"

    self = node()

    # query for all ips responding to a given dns query
    query
    |> String.to_charlist
    |> :inet_res.lookup(:in, :a)
    |> Enum.map(&format_node(&1, node_sname)) # format ips as node names
    |> Enum.reject(fn(n) -> n == self end)    # filter out self
    |> handle_poll(state)

    # reschedule a call to itself in poll_interval ms
    Process.send_after(self(), :poll, poll_interval)

    {:noreply, state}
  end

  # turn an ip into a node name atom, assuming that all other node names looks similar to our own name
  defp format_node({a, b, c, d}, sname), do: "#{sname}@#{a}.#{b}.#{c}.#{d}" |> String.to_atom

  # handle connecting to all nodes found
  defp handle_poll(nodes, %State{connect: connect, list_nodes: list_nodes} = state) do
    debug state.topology, "found nodes #{inspect(nodes)}"
    Cluster.Strategy.connect_nodes(state.topology, connect, list_nodes, nodes)
    :ok
  end
end
