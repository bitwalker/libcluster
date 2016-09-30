defmodule Cluster.Events do
  @moduledoc """
  This module implements a publish/subscribe mechanism for cluster events.
  """
  import Cluster.Logger

  # Public API

  @doc """
  Subscribes a process (by pid) to cluster events.
  """
  @spec subscribe(pid) :: :ok
  def subscribe(pid) do
    send(__MODULE__, {:subscribe, pid})
    :ok
  end

  @doc """
  Unsubscribes a process (by pid) from cluster events.
  """
  @spec unsubscribe(pid) :: :ok
  def unsubscribe(pid) do
    send(__MODULE__, {:unsubscribe, pid})
    :ok
  end

  @doc """
  Publishes an event to all subscribers.

  Published messages are delivered via `send/2`, so if subscribing
  a gen_* process, you will receive them in the `handle_info/2` callback.
  """
  @spec publish(event :: term()) :: :ok
  def publish(event) do
    send(__MODULE__, {:publish, event})
    :ok
  end

  # Helpers

  defmacrop handle_debug(debug, msg) do
    quote do
      :sys.handle_debug(unquote(debug), &write_debug/3, nil, unquote(msg))
    end
  end

  ## Process implementation

  def start_link() do
    :proc_lib.start_link(__MODULE__, :init, [self()], :infinity, [:link])
  end

  def init(parent) do
    # register as Cluster.Events
    Process.register(self(), __MODULE__)
    # Trap exits
    Process.flag(:trap_exit, true)
    # Tell the supervisor we've started
    :proc_lib.init_ack(parent, {:ok, self()})
    debug = :sys.debug_options([])
    # Monitor node events
    :ok = :net_kernel.monitor_nodes(true, [node_type: :all])
    loop(%{}, parent, debug)
  end

  defp loop(subscribers, parent, debug) do
    receive do
      # System messages take precedence, as does the parent process exiting
      {:system, from, request} ->
        :sys.handle_system_msg(request, from, parent, __MODULE__, debug, nil)
      # Parent supervisor is telling us to exit
      {:EXIT, ^parent, reason} ->
        warn "[events] exiting: #{inspect reason}"
        exit(reason)
      {:nodeup, node, _info} = msg ->
        debug = handle_debug(debug, {:in, msg})
        for {pid, _} <- subscribers, do: send(pid, {:nodeup, node})
        loop(subscribers, parent, debug)
      {:nodedown, node, _info} = msg ->
        debug = handle_debug(debug, {:in, msg})
        for {pid, _} <- subscribers, do: send(pid, {:nodedown, node})
        loop(subscribers, parent, debug)
      {:subscribe, pid} = msg ->
        debug = handle_debug(debug, {:in, msg})
        case Map.get(subscribers, pid) do
          nil ->
            ref = Process.monitor(pid)
            loop(Map.put(subscribers, pid, ref), parent, debug)
          _ ->
            loop(subscribers, parent, debug)
        end
      {:unsubscribe, pid} = msg ->
        debug = handle_debug(debug, {:in, msg})
        case Map.pop(subscribers, pid) do
          {nil, _} ->
            loop(subscribers, parent, debug)
          {ref, subscribers} ->
            Process.demonitor(ref, [:flush])
            loop(subscribers, parent, debug)
        end
      {:publish, event} = msg ->
        debug = handle_debug(debug, {:in, msg})
        for {pid, _} <- subscribers, do: send(pid, event)
        loop(subscribers, parent, debug)
      {:DOWN, ref, _type, pid, _info} = msg ->
        debug = handle_debug(debug, {:in, msg})
        case Map.pop(subscribers, pid) do
          {^ref, subscribers} ->
            loop(subscribers, parent, debug)
          {nil, _} ->
            loop(subscribers, parent, debug)
        end
    end
  end

  # Sys module callbacks

  # Handle resuming this process after it's suspended by :sys
  # We're making a bit of an assumption here that it won't be suspended
  # prior to entering the receive loop. This is something we (probably) could
  # fix by storing the current phase of the startup the process is in, but I'm not sure.
  def system_continue(parent, debug, state),
    do: loop(state, parent, debug)

  # Handle system shutdown gracefully
  def system_terminate(_reason, :application_controller, _debug, _state) do
    # OTP-5811 Don't send an error report if it's the system process
    # application_controller which is terminating - let init take care
    # of it instead
    :ok
  end
  def system_terminate(:normal, _parent, _debug, _state) do
    exit(:normal)
  end
  def system_terminate(reason, _parent, debug, state) do
    :error_logger.format('** ~p terminating~n
                          ** Server state was: ~p~n
                          ** Reason: ~n** ~p~n', [__MODULE__, state, reason])
    :sys.print_log(debug)
    exit(reason)
  end

  # Used for fetching the current process state
  def system_get_state(state), do: {:ok, state}

  # Called when someone asks to replace the current process state
  # Required, but you really really shouldn't do this.
  def system_replace_state(state_fun, state) do
    new_state = state_fun.(state)
    {:ok, new_state, new_state}
  end

  # Called when the system is upgrading this process
  def system_code_change(misc, _module, _old, _extra) do
    {:ok, misc}
  end

  defp write_debug(_dev, {:in, msg, from}, _ctx) do
    Cluster.Logger.debug("[events] <== #{inspect msg} from #{inspect from}")
  end
  defp write_debug(_dev, {:in, msg}, _ctx) do
    Cluster.Logger.debug("[events] <== #{inspect msg}")
  end
  defp write_debug(_dev, {:out, msg, to}, _ctx) do
    Cluster.Logger.debug("[events] ==> #{inspect msg} to #{inspect to}")
  end
  defp write_debug(_dev, {:out, msg}, _ctx) do
    Cluster.Logger.debug("[events] ==> #{inspect msg}")
  end
  defp write_debug(_dev, event, _ctx) do
    Cluster.Logger.debug("[events] #{inspect event}")
  end

end
