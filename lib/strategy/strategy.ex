defmodule Cluster.Strategy do
  @moduledoc """
  This module defines the behaviour for implementing clustering strategies.
  """
  defmacro __using__(_) do
    quote do
      @behaviour Cluster.Strategy

      @impl true
      def child_spec(args) do
        %{id: __MODULE__, type: :worker, start: {__MODULE__, :start_link, [args]}}
      end

      defoverridable child_spec: 1
    end
  end

  @type topology :: atom
  @type bad_nodes :: [{node, reason :: term}]
  @type mfa_tuple :: {module, atom, [term]}
  @type strategy_args :: [Cluster.Strategy.State.t()]

  # Required for supervision of the strategy
  @callback child_spec(strategy_args) :: Supervisor.child_spec()
  # Starts the strategy
  @callback start_link(strategy_args) :: {:ok, pid} | :ignore | {:error, reason :: term}

  @doc """
  Given a list of node names, attempts to connect to all of them.
  Returns `:ok` if all nodes connected, or `{:error, [{node, reason}, ..]}`
  if we failed to connect to some nodes.

  All failures are logged.
  """
  @spec connect_nodes(topology, mfa_tuple, mfa_tuple, [atom()]) :: :ok | {:error, bad_nodes}
  def connect_nodes(topology, {_, _, _} = connect, {_, _, _} = list_nodes, nodes)
      when is_list(nodes) do
    {connect_mod, connect_fun, connect_args} = connect
    {list_mod, list_fun, list_args} = list_nodes
    ensure_exported!(list_mod, list_fun, length(list_args))
    current_node = Node.self()

    need_connect =
      nodes
      |> difference(apply(list_mod, list_fun, list_args))
      |> Enum.reject(fn n -> current_node == n end)

    bad_nodes =
      Enum.reduce(need_connect, [], fn n, acc ->
        fargs = connect_args ++ [n]
        ensure_exported!(connect_mod, connect_fun, length(fargs))

        case apply(connect_mod, connect_fun, fargs) do
          true ->
            Cluster.Logger.info(topology, "connected to #{inspect(n)}")
            acc

          false ->
            Cluster.Logger.warn(topology, "unable to connect to #{inspect(n)}")
            [{n, false} | acc]

          :ignored ->
            Cluster.Logger.warn(
              topology,
              "unable to connect to #{inspect(n)}: not part of network"
            )

            [{n, :ignored} | acc]
        end
      end)

    case bad_nodes do
      [] -> :ok
      _ -> {:error, bad_nodes}
    end
  end

  @doc """
  Given a list of node names, attempts to disconnect from all of them.
  Returns `:ok` if all nodes disconnected, or `{:error, [{node, reason}, ..]}`
  if we failed to disconnect from some nodes.

  All failures are logged.
  """
  @spec disconnect_nodes(topology, mfa_tuple, mfa_tuple, [atom()]) :: :ok | {:error, bad_nodes}
  def disconnect_nodes(topology, {_, _, _} = disconnect, {_, _, _} = list_nodes, nodes)
      when is_list(nodes) do
    {disconnect_mod, disconnect_fun, disconnect_args} = disconnect
    {list_mod, list_fun, list_args} = list_nodes
    ensure_exported!(list_mod, list_fun, length(list_args))
    current_node = Node.self()

    need_disconnect =
      nodes
      |> intersection(apply(list_mod, list_fun, list_args))
      |> Enum.reject(fn n -> current_node == n end)

    bad_nodes =
      Enum.reduce(need_disconnect, [], fn n, acc ->
        fargs = disconnect_args ++ [n]
        ensure_exported!(disconnect_mod, disconnect_fun, length(fargs))

        case apply(disconnect_mod, disconnect_fun, fargs) do
          true ->
            Cluster.Logger.info(topology, "disconnected from #{inspect(n)}")
            acc

          false ->
            Cluster.Logger.warn(
              topology,
              "disconnect from #{inspect(n)} failed because we're already disconnected"
            )

            acc

          :ignored ->
            Cluster.Logger.warn(
              topology,
              "disconnect from #{inspect(n)} failed because it is not part of the network"
            )

            acc

          reason ->
            Cluster.Logger.warn(
              topology,
              "disconnect from #{inspect(n)} failed with: #{inspect(reason)}"
            )

            [{n, reason} | acc]
        end
      end)

    case bad_nodes do
      [] -> :ok
      _ -> {:error, bad_nodes}
    end
  end

  def intersection(_a, []), do: []
  def intersection([], _b), do: []

  def intersection(a, b) when is_list(a) and is_list(b) do
    a |> MapSet.new() |> MapSet.intersection(MapSet.new(b))
  end

  def difference(a, []), do: a
  def difference([], _b), do: []

  def difference(a, b) when is_list(a) and is_list(b) do
    a |> MapSet.new() |> MapSet.difference(MapSet.new(b))
  end

  defp ensure_exported!(mod, fun, arity) do
    unless function_exported?(mod, fun, arity) do
      raise "#{mod}.#{fun}/#{arity} is undefined!"
    end
  end
end
