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
              heartbeat: 3_000, # the random range for heartbeating
              hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]]]]

  """
  use Cluster.Strategy

  alias Cluster.Strategy.State

  def start_link([%State{config: config} = state]) do
    case Keyword.get(config, :hosts, []) do
      [] ->
        :ignore

      nodes when is_list(nodes) ->
        GenServer.start_link(__MODULE__, state)
    end
  end

  def init(state) do
    {:ok, state, {:continue, nil}}
  end

  def handle_continue(_, state), do: handle_info(:heartbeat, state)

  def handle_info(:heartbeat, %State{config: config} = state) do
    handle_heartbeat(state)
    Process.send_after(self, :heartbeat, :rand.uniform(Keyword.get(config, :heartbeat, 3_000)))
    {:noreply, state}
  end

  @spec handle_heartbeat(State.t()) :: :ok
  defp handle_heartbeat(%State{config: config} = state) do
    case Keyword.get(config, :hosts, []) do
      [] ->
        :ignore

      nodes when is_list(nodes) ->
        Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
    end
  end
end
