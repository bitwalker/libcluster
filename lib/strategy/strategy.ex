defmodule Cluster.Strategy do
  @moduledoc """
  This module defines the behaviour for implementing clustering strategies.
  """
  defmacro __using__(_) do
    quote do
      @behaviour Cluster.Strategy
    end
  end

  @type topology :: atom()
  @type bad_nodes :: [{node(), reason :: term()}]
  @type mfa_tuple :: {module(), atom(), [term()]}
  @type strategy_opts :: [topology: atom(),
                          connect: mfa_tuple,
                          disconnect: mfa_tuple]

  # Starts the strategy
  @callback start_link(strategy_opts) :: {:ok, pid} | :ignore | {:error, reason :: term}

  @doc false
  def connect_nodes(topology, {_mod, _fun, _args} = connect_mfa, nodes) do
    IO.warn "connect_nodes/3 has been deprecated, please update your strategy to use connect_nodes/4"
    list_nodes_mfa = {:erlang, :nodes, [:connected]}
    connect_nodes(topology, connect_mfa, list_nodes_mfa, nodes)
  end

  @doc """
  Given a list of node names, attempts to connect to all of them.
  Returns `:ok` if all nodes connected, or `{:error, [{node, reason}, ..]}`
  if we failed to connect to some nodes.

  All failures are logged.
  """
  @spec connect_nodes(topology, mfa_tuple, mfa_tuple, [atom()]) :: :ok | {:error, bad_nodes}
  def connect_nodes(topology, {_,_,_} = connect, {_,_,_} = list_nodes, nodes) when is_list(nodes) do
    {connect_mod, connect_fun, connect_args} = connect
    {list_mod, list_fun, list_args} = list_nodes
    ensure_exported!(list_mod, list_fun, length(list_args))
    need_connect = difference(nodes, apply(list_mod, list_fun, list_args))
    bad_nodes = Enum.reduce(need_connect, [], fn n, acc ->
      fargs = connect_args++[n]
      ensure_exported!(connect_mod, connect_fun, length(fargs))
      case apply(connect_mod, connect_fun, fargs) do
        true ->
          Cluster.Logger.info topology, "connected to #{inspect n}"
          acc
        false ->
          Cluster.Logger.warn topology, "unable to connect to #{inspect n}"
          [{n, false}|acc]
        :ignored ->
          Cluster.Logger.warn topology, "unable to connect to #{inspect n}: not part of network"
          [{n, :ignored}|acc]
      end
    end)
    case bad_nodes do
      [] -> :ok
      _  -> {:error, bad_nodes}
    end
  end

  @doc false
  def disconnect_nodes(topology, {_,_,_} = disconnect_mfa, nodes) do
    IO.warn "disconnect_nodes/3 has been deprecated, please update your strategy to use disconnect_nodes/4"
    list_nodes_mfa = {:erlang, :nodes, [:connected]}
    disconnect_nodes(topology, disconnect_mfa, list_nodes_mfa, nodes)
  end

  @doc """
  Given a list of node names, attempts to disconnect from all of them.
  Returns `:ok` if all nodes disconnected, or `{:error, [{node, reason}, ..]}`
  if we failed to disconnect from some nodes.

  All failures are logged.
  """
  @spec disconnect_nodes(topology, mfa_tuple, [atom()]) :: :ok | {:error, bad_nodes}
  def disconnect_nodes(topology, {_,_,_} = disconnect, {_,_,_} = list_nodes, nodes) when is_list(nodes) do
    {disconnect_mod, disconnect_fun, disconnect_args} = disconnect
    {list_mod, list_fun, list_args} = list_nodes
    ensure_exported!(list_mod, list_fun, length(list_args))
    need_disconnect = intersection(nodes, apply(list_mod, list_fun, list_args))
    bad_nodes = Enum.reduce(need_disconnect, [], fn n, acc ->
      fargs = disconnect_args++[n]
      ensure_exported!(disconnect_mod, disconnect_fun, length(fargs))
      case apply(disconnect_mod, disconnect_fun, fargs) do
        true ->
          Cluster.Logger.info topology, "disconnected from #{inspect n}"
          acc
        false ->
          Cluster.Logger.warn topology, "disconnect from #{inspect n} failed because we're already disconnected"
          acc
        :ignored ->
          Cluster.Logger.warn topology, "disconnect from #{inspect n} failed because it is not part of the network"
          acc
      end
    end)
    case bad_nodes do
      [] -> :ok
      _  -> {:error, bad_nodes}
    end
  end

  def intersection(a, []), do: []
  def intersection([], b), do: []
  def intersection(a, b) when is_list(a) and is_list(b) do
    a |> MapSet.new |> MapSet.intersection(MapSet.new(b))
  end

  def difference(a, []), do: a
  def difference([], b), do: []
  def difference(a, b) when is_list(a) and is_list(b) do
    a |> MapSet.new |> MapSet.difference(MapSet.new(b))
  end

  defp ensure_exported!(mod, fun, arity) do
    unless :erlang.function_exported(mod, fun, arity) do
      raise "#{mod}.#{fun}/#{arity} is undefined!"
    end
  end
end
