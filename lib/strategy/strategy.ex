defmodule Cluster.Strategy do
  @moduledoc """
  This module defines the behaviour for implementing clustering strategies.
  """
  defmacro __using__(_) do
    quote do
      @behaviour Cluster.Strategy
    end
  end

  @type bad_nodes :: [{node(), reason :: term()}]

  # Starts the strategy
  @callback start_link() :: {:ok, pid} | :ignore | {:error, reason :: term}

  @doc """
  Returns a worker specification for the selected cluster strategy.
  """
  @spec spec() :: Supervisor.Spec.spec()
  def spec(), do: Supervisor.Spec.worker(selected_strategy(), [])

  @doc """
  Starts the selected cluster strategy process.
  """
  @spec start_link() :: {:ok, pid} | :ignore | {:error, reason :: term}
  def start_link(), do: apply(selected_strategy(), :start_link, [])

  @doc false
  @spec selected_strategy() :: module()
  def selected_strategy(),
    do: Application.get_env(:libcluster, :strategy, Cluster.Strategy.Epmd)

  @doc """
  Given a list of node names, attempts to connect to all of them.
  Returns `:ok` if all nodes connected, or `{:error, [{node, reason}, ..]}`
  if we failed to connect to some nodes.

  All failures are logged.
  """
  @spec connect_nodes([atom()]) :: :ok | {:error, bad_nodes}
  def connect_nodes(nodes) when is_list(nodes) do
    bad_nodes = Enum.reduce(nodes, [], fn n, acc ->
      case :net_kernel.connect_node(n) do
        true ->
          Cluster.Logger.info "connected to #{inspect n}"
          acc
        reason ->
          Cluster.Logger.warn "attempted to connect to node (#{inspect n}), but failed with #{reason}."
          [{n, reason}|acc]
      end
    end)
    case bad_nodes do
      [] -> :ok
      _  -> {:error, bad_nodes}
    end
  end
end
