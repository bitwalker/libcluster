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
            config: [timeout: 30_000, name_match: "a"]
          ]
        ]

  ## Options

  * `timeout` - This is the timeout that will be used in the GenServer to connect the nodes.
  This defaults to `:infinity` meaning that the connection process will only happen when the
  worker is started. Any integer timeout will result in the connection process
  being triggered. In the example above, it has been configured for 30 seconds. (optional; default: :infinity)
  * `name_match` - Only connect that node which match the name of prefix. (optional; default: nil)

  |         :name_match         |             type             | :"a@127.0.0.1" | :"b@127.0.0.1" | :"a1@127.0.0.1" | :"b1@127.0.0.1" |
  |             :a              |            atom()            |       √        |       ×        |        ×        |        ×        |
  |          [:a, :b]           |           [atom()]           |       √        |       √        |        ×        |        ×        |
  |            'a1'             |          charlist()          |       ×        |       ×        |        √        |        ×        |
  |             "1"             |          String.t()          |       ×        |       ×        |        √        |        √        |
  |           ~r/^a/            |          Regex.t()           |       √        |       ×        |        √        |        ×        |
  | &String.ends_with(&1, "1")  |            fun()             |       ×        |       ×        |        √        |        √        |
  |    {String, :printable?}    |      {module(), atom()}      |       √        |       √        |        √        |        √        |
  | {String, :ends_with, ["1"]} | {module(), atom(), [term()]} |       ×        |       ×        |        √        |        √        |
  """
  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  def start_link([%State{topology: topology} = state]) do
    case :net_adm.host_file() do
      {:error, _} ->
        Cluster.Logger.warn(topology, "couldn't find .hosts.erlang file - not joining cluster")
        :ignore

      hosts ->
        new_state = %State{state | :meta => hosts}
        GenServer.start_link(__MODULE__, [new_state])
    end
  end

  @impl true
  def init([state]) do
    new_state =
      state
      |> append_name_matcher()
      |> connect_hosts()

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

  defp append_name_matcher(%State{config: config, meta: hosts} = state) do
    name_matcher =
      case Keyword.get(config, :name_match) do
        nil ->
          nil

        atom when is_atom(atom) ->
          string = to_string(atom)
          &(string == to_string(&1))

        [atom | _] = atom_list when is_atom(atom) ->
          list = Enum.map(atom_list, &to_string/1)
          &Enum.member?(list, to_string(&1))

        [int | _] = charlist when is_integer(int) ->
          &(charlist == &1)

        string when is_binary(string) ->
          &String.contains?(to_string(&1), string)

        %Regex{} = reg ->
          &String.match?(to_string(&1), reg)

        fun when is_function(fun, 1) ->
          &fun.(to_string(&1))

        {m, f} ->
          &apply(m, f, [to_string(&1)])

        {m, f, args} ->
          &apply(m, f, [to_string(&1) | args])

        _unsupported ->
          nil
      end

    %{state | meta: {name_matcher, hosts}}
  end

  defp configured_timeout(%State{config: config}) do
    Keyword.get(config, :timeout, :infinity)
  end

  defp connect_hosts(%State{meta: {name_matcher, hosts}} = state) do
    nodes =
      hosts
      |> Enum.map(&{:net_adm.names(&1), &1})
      |> gather_node_names(name_matcher, [])
      |> List.delete(node())

    Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
    state
  end

  defp gather_node_names([], _name_matcher, acc), do: acc

  defp gather_node_names([{{:ok, names}, host} | rest], name_matcher, acc) do
    names =
      if name_matcher do
        Enum.reduce(names, acc, fn {name, _}, acc ->
          if name_matcher.(name) do
            node_name = String.to_atom("#{name}@#{host}")
            [node_name | acc]
          else
            acc
          end
        end)
      else
        Enum.map(names, fn {name, _} -> String.to_atom("#{name}@#{host}") end) ++ acc
      end

    gather_node_names(rest, name_matcher, names)
  end

  defp gather_node_names([_ | rest], name_matcher, acc),
    do: gather_node_names(rest, name_matcher, acc)
end
