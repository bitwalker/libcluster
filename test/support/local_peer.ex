defmodule Cluster.LocalPeer do
  @moduledoc false

  import ExUnit.Callbacks

  def start(name, cookie) do
    paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)

    options = %{
      name: name,
      host: ~c"127.0.0.1",
      longnames: true,
      connection: :standard_io,
      wait_boot: 15_000,
      args:
        [
          ~c"+S",
          ~c"2",
          ~c"-setcookie",
          String.to_charlist(cookie),
          ~c"-kernel",
          ~c"inet_dist_use_interface",
          ~c"{127,0,0,1}"
        ] ++ paths
    }

    peer = start_supervised!(%{id: make_ref(), start: {peer_module(), :start_link, [options]}})
    {:ok, _} = call(peer, :application, :ensure_all_started, [:libcluster])
    call(peer, System, :put_env, ["CLUSTER_DOMAIN", ""])
    {peer, call(peer, Node, :self, [])}
  end

  def call(peer, module, function, args) do
    apply(peer_module(), :call, [peer, module, function, args, 15_000])
  end

  def poll(peer, strategy), do: call(peer, __MODULE__, :poll_strategy, [strategy])

  def await_nodes(peer, expected), do: call(peer, __MODULE__, :wait_nodes, [expected])

  def wait_nodes(expected) do
    :ok = :net_kernel.monitor_nodes(true)

    try do
      wait_nodes(MapSet.new(expected), System.monotonic_time(:millisecond) + 5_000)
    after
      :net_kernel.monitor_nodes(false)
    end
  end

  defp wait_nodes(expected, deadline) do
    actual = Node.list(:connected)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      MapSet.new(actual) == expected ->
        :ok

      remaining <= 0 ->
        {:error, {:unexpected_nodes, actual}}

      true ->
        receive do
          {event, _node} when event in [:nodeup, :nodedown] -> wait_nodes(expected, deadline)
        after
          remaining -> {:error, {:unexpected_nodes, Node.list(:connected)}}
        end
    end
  end

  def poll_strategy(strategy) do
    send(strategy, :load)
    :sys.get_state(strategy)
  end

  def start_discovery(topologies) do
    {:ok, root} =
      Supervisor.start_link([{Cluster.Supervisor, [topologies]}], strategy: :one_for_one)

    # The RPC worker exits after returning. The disposable peer node owns this
    # tree's lifetime, so it must not remain linked to that short-lived caller.
    Process.unlink(root)
    root
  end

  # Keep OTP24 compilation independent of :peer, which was introduced in OTP25.
  defp peer_module, do: :peer
end
