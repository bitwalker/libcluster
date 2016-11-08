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

  @doc """
  Given a list of node names, attempts to connect to all of them.
  Returns `:ok` if all nodes connected, or `{:error, [{node, reason}, ..]}`
  if we failed to connect to some nodes.

  All failures are logged.
  """
  @spec connect_nodes(topology, mfa_tuple, [atom()]) :: :ok | {:error, bad_nodes}
  def connect_nodes(topology, {mod, fun, args}, nodes) when is_list(nodes) do
    bad_nodes = Enum.reduce(nodes, [], fn n, acc ->
      fargs = args++[n]
      unless :erlang.function_exported(mod, fun, length(fargs)) do
        fstr = "#{mod}.#{fun}/#{length(fargs)}"
        raise "#{fstr} is undefined!"
      end
      case apply(mod, fun, fargs) do
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

  @doc """
  Given a list of node names, attempts to disconnect from all of them.
  Returns `:ok` if all nodes disconnected, or `{:error, [{node, reason}, ..]}`
  if we failed to disconnect from some nodes.

  All failures are logged.
  """
  @spec disconnect_nodes(topology, mfa_tuple, [atom()]) :: :ok | {:error, bad_nodes}
  def disconnect_nodes(topology, {mod, fun, args}, nodes) when is_list(nodes) do
    bad_nodes = Enum.reduce(nodes, [], fn n, acc ->
      fargs = args++[n]
      unless :erlang.function_exported(mod, fun, length(fargs)) do
        fstr = "#{mod}.#{fun}/#{length(fargs)}"
        raise "#{fstr} is undefined!"
      end
      case apply(mod, fun, fargs) do
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
end
