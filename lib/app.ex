defmodule Cluster.App do
  @doc false
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = get_child_specs()
    opts = [strategy: :one_for_one, name: Cluster.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Manually start a cluster topology.

  You must provide a topology name as an atom, and a keyword list of options, in the same
  form you would define them in `config.exs`
  """
  def start_topology(topology, spec \\ []) when is_atom(topology) and is_list(spec) do
    import Supervisor.Spec

    strategy = Keyword.fetch!(spec, :strategy)
    worker_args = [{:topology, topology} | extract_args(spec)]
    opts = Keyword.get(spec, :child_spec, [])

    Supervisor.start_child(Cluster.Supervisor, worker(strategy, worker_args, opts))
  end

  defp get_child_specs() do
    import Supervisor.Spec, warn: false
    specs = Application.get_env(:libcluster, :topologies, [])

    for {topology, spec} <- specs do
      strategy = Keyword.fetch!(spec, :strategy)
      worker_args = [{:topology, topology} | extract_args(spec)]
      opts = Keyword.get(spec, :child_spec, [])

      worker(strategy, worker_args, opts)
    end
  end

  defp extract_args(spec) do
    config = Keyword.get(spec, :config, [])
    connect_mfa = Keyword.get(spec, :connect, {:net_kernel, :connect, []})
    disconnect_mfa = Keyword.get(spec, :disconnect, {:net_kernel, :disconnect, []})
    list_nodes_mfa = Keyword.get(spec, :list_nodes, {:erlang, :nodes, [:connected]})

    [
      connect: connect_mfa,
      disconnect: disconnect_mfa,
      list_nodes: list_nodes_mfa,
      config: config
    ]
  end
end
