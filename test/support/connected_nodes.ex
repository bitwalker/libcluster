defmodule Cluster.ConnectedNodes do
  @moduledoc false
  use Agent

  def start_link(owner) do
    Agent.start_link(fn ->
      %{owner: owner, nodes: MapSet.new(), connect: true, disconnect: true}
    end)
  end

  def list_nodes(server), do: Agent.get(server, &MapSet.to_list(&1.nodes))

  def set_connected(server, nodes) do
    Agent.update(server, &%{&1 | nodes: MapSet.new(nodes)})
  end

  def set_result(server, operation, result) do
    Agent.update(server, &Map.replace!(&1, operation, result))
  end

  def connect(server, node), do: change(server, :connect, node)
  def disconnect(server, node), do: change(server, :disconnect, node)

  defp change(server, operation, node) do
    Agent.get_and_update(server, fn state ->
      result = Map.fetch!(state, operation)

      nodes =
        case {operation, result} do
          {:connect, true} -> MapSet.put(state.nodes, node)
          {:disconnect, true} -> MapSet.delete(state.nodes, node)
          _ -> state.nodes
        end

      send(state.owner, {operation, node})
      {result, %{state | nodes: nodes}}
    end)
  end
end
