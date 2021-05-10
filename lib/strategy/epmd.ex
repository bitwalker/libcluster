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
              hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]]]]

  """
  alias Cluster.{Strategy, Strategy.State}

  use Cluster.Strategy
  use GenServer

  @default_polling_interval 5_000

  @impl true
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{} = state]), do: {:ok, state, {:continue, :load}}

  @impl true
  def handle_continue(:load, %State{} = state), do: load(state)

  @impl true
  def handle_info(:timeout, %State{} = state), do: load(state)

  def handle_info(:clean, state), do: clean(state)

  def handle_info(_, state), do: {:noreply, state}

  defp load(%State{config: config} = state) do
    nodes = config |> Keyword.get(:hosts, []) |> connect_nodes(state)

    Process.send_after(self(), :clean, polling_interval(state))

    {:noreply, %State{state | meta: nodes}}
  end

  defp clean(%State{list_nodes: list_nodes, meta: prev_nodes} = state) do
    {list_mod, list_fun, list_args} = list_nodes
    current_nodes = apply(list_mod, list_fun, list_args)

    nodes =
      prev_nodes
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(current_nodes))
      |> MapSet.to_list()
      |> disconnect_nodes(current_nodes, state)

    Process.send_after(self(), :clean, polling_interval(state))

    {:noreply, %State{state | meta: nodes}}
  end

  defp connect_nodes(nodes, %State{} = state) do
    case Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes) do
      :ok ->
        nodes

      {:error, bad_nodes} ->
        # Remove the nodes which should have been added, but couldn't be for some reason
        bad_nodes
        |> Enum.reduce(MapSet.new(nodes), fn {n, _}, acc -> MapSet.delete(acc, n) end)
        |> MapSet.to_list()
    end
  end

  defp disconnect_nodes(removed, current, %State{} = state) do
    case Strategy.disconnect_nodes(state.topology, state.disconnect, state.list_nodes, removed) do
      :ok ->
        current

      {:error, bad_nodes} ->
        # Add back the nodes which should have been removed, but which couldn't be for some reason
        bad_nodes
        |> Enum.reduce(MapSet.new(current), fn {n, _}, acc -> MapSet.put(acc, n) end)
        |> MapSet.to_list()
    end
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end
end
