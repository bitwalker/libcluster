defmodule Cluster.Strategy.Epmd do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol
  """
  use Cluster.Strategy

  def start_link(), do: :ignore
end
