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
              timeout: 30_000,
              hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]]]]

  An optional timeout can be specified in the config. This is the timeout that
  will be used in the GenServer to connect the nodes. This defaults to
  `:infinity` meaning that the connection process will only happen when the
  worker is started. Any integer timeout will result in the connection process
  being triggered. In the example above, it has been configured for 30 seconds.
  """
  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  @impl true
  def start_link([%State{config: config} = state]) do
    case Keyword.get(config, :hosts, []) do
      [] ->
        :ignore

      nodes when is_list(nodes) ->
        GenServer.start_link(__MODULE__, [state])
    end
  end

  @impl true
  def init([state]) do
    connect_hosts(state)
    {:ok, state, configured_timeout(state)}
  end

  @impl true
  def handle_info(:timeout, state) do
    handle_info(:connect, state)
  end

  def handle_info(:connect, state) do
    connect_hosts(state)
    {:noreply, state, configured_timeout(state)}
  end

  @spec configured_timeout(State.t()) :: integer() | :infinity
  defp configured_timeout(%State{config: config}) do
    Keyword.get(config, :timeout, :infinity)
  end

  @spec connect_hosts(State.t()) :: State.t()
  defp connect_hosts(%State{config: config} = state) do
    nodes = Keyword.get(config, :hosts, [])
    Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
    state
  end
end
