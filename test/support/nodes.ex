defmodule Cluster.Nodes do
  @moduledoc false

  def connect(caller, result \\ true, node) do
    send(caller, {:connect, node})
    result
  end

  def disconnect(caller, result \\ true, node) do
    send(caller, {:disconnect, node})
    result
  end

  def list_nodes(nodes) do
    nodes
  end
end
