defmodule Cluster.Strategy.ErlangHosts do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol by
  using a `.hosts.erlang` file (as used by the `:net_adm` module).

  Please see [the net_adm docs](http://erlang.org/doc/man/net_adm.html) for more details.

  In short, the following is the gist of how it works:

  > File `.hosts.erlang` consists of a number of host names written as Erlang terms. It is looked for in the current work
  > directory, the user's home directory, and $OTP_ROOT (the root directory of Erlang/OTP), in that order.

  This looks a bit like the following in practice:

  ```erlang
  'super.eua.ericsson.se'.
  'renat.eua.ericsson.se'.
  'grouse.eua.ericsson.se'.
  'gauffin1.eua.ericsson.se'.

  ```

  You can have `libcluster` automatically connect nodes on startup for you by configuring
  the strategy like below:

      config :libcluster,
        topologies: [
          erlang_hosts_example: [
            strategy: #{__MODULE__},
            config: [timeout: 30_000]
          ]
        ]

  An optional timeout can be specified in the config. This is the timeout that
  will be used in the GenServer to connect the nodes. This defaults to
  `:infinity` meaning that the connection process will only happen when the
  worker is started. Any integer timeout will result in the connection process
  being triggered. In the example above, it has been configured for 30 seconds.
  """
  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  def start_link([%State{topology: topology} = state]) do
    case :net_adm.host_file() do
      {:error, _} ->
        Cluster.Logger.warn(topology, "couldn't find .hosts.erlang file - not joining cluster")
        :ignore

      file ->
        new_state = %State{state | :meta => file}
        GenServer.start_link(__MODULE__, [new_state])
    end
  end

  @impl true
  def init([state]) do
    new_state = connect_hosts(state)
    {:ok, new_state, configured_timeout(new_state)}
  end

  @impl true
  def handle_info(:timeout, state) do
    handle_info(:connect, state)
  end

  def handle_info(:connect, state) do
    new_state = connect_hosts(state)
    {:noreply, new_state, configured_timeout(new_state)}
  end

  defp configured_timeout(%State{config: config}) do
    Keyword.get(config, :timeout, :infinity)
  end

  defp connect_hosts(%State{meta: hosts_file} = state) do
    nodes =
      hosts_file
      |> Enum.map(&{:net_adm.names(&1), &1})
      |> gather_node_names([])
      |> List.delete(node())

    Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
    state
  end

  defp gather_node_names([], acc), do: acc

  defp gather_node_names([{{:ok, names}, host} | rest], acc) do
    names = Enum.map(names, fn {name, _} -> String.to_atom("#{name}@#{host}") end)
    gather_node_names(rest, names ++ acc)
  end

  defp gather_node_names([_ | rest], acc), do: gather_node_names(rest, acc)
end
