defmodule Cluster.Supervisor do
  @moduledoc """
  This module handles supervising the configured topologies, and is designed
  to support being started within your own supervision tree, as shown below:

      defmodule MyApp.App do
        use Application

        def start(_type, _args) do
          topologies = [
            example: [
              strategy: Cluster.Strategy.Epmd,
              config: [hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]],
            ]
          ]
          children = [
            {Cluster.Supervisor, [topologies, [name: MyApp.ClusterSupervisor]]},
            ..other children..
          ]
          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  The `topologies` configuration structure shown above can be built manually,
  like shown, so that you can load config at runtime in a way that best
  suits your application; or if you don't need to do any special config
  handling, you can use the Mix config file, and just use
  `Application.get_env(:libcluster, :topologies)`. That config would look like so:

      config :libcluster,
        topologies: [
          example: [...]
        ]

  Use the method most convenient for you.
  """
  use Supervisor

  @doc """
  Start a new instance of this supervisor. This is the callback indicated in
  the child specification returned by `child_spec/1`. It expects a list of
  the form `[config, supervisor_opts]`, or `[config]`. The former allows you
  to provide options for the supervisor like with `Supervisor.start_link/3`.
  """
  def start_link([_config, opts] = args) do
    Supervisor.start_link(__MODULE__, args, opts)
  end

  def start_link([config]) do
    start_link([config, []])
  end

  @doc false
  @impl Supervisor
  def init([config, opts]) do
    opts = Keyword.put(opts, :strategy, :one_for_one)
    children = get_configured_topologies(config)
    Supervisor.init(children, opts)
  end

  defp get_configured_topologies(config) do
    for {topology, spec} <- config do
      strategy = Keyword.fetch!(spec, :strategy)
      state = build_initial_state([{:topology, topology} | spec])

      %{
        id: state.topology,
        start: {strategy, :start_link, [[state]]}
      }
    end
  end

  defp build_initial_state(spec) do
    topology = Keyword.fetch!(spec, :topology)
    config = Keyword.get(spec, :config, [])
    connect_mfa = Keyword.get(spec, :connect, {:net_kernel, :connect_node, []})
    disconnect_mfa = Keyword.get(spec, :disconnect, {:erlang, :disconnect_node, []})
    list_nodes_mfa = Keyword.get(spec, :list_nodes, {:erlang, :nodes, [:connected]})

    %Cluster.Strategy.State{
      topology: topology,
      connect: connect_mfa,
      disconnect: disconnect_mfa,
      list_nodes: list_nodes_mfa,
      config: config,
      meta: nil
    }
  end
end
