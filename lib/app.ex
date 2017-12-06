defmodule Cluster.App do
  @doc false
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = get_child_specs()
    opts = [strategy: :one_for_one, name: Cluster.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp get_child_specs() do
    import Supervisor.Spec, warn: false
    Application.get_env(:libcluster, :topologies, [])
    |> Enum.filter(&filter_for_applied_topologies(&1, Application.get_env(:libcluster, :applied_topologies)))
    |> Enum.each(fn({topology, spec}) ->
      strategy       = Keyword.fetch!(spec, :strategy)
      config         = Keyword.get(spec, :config, [])
      connect_mfa    = Keyword.get(spec, :connect, {:net_kernel, :connect, []})
      disconnect_mfa = Keyword.get(spec, :disconnect, {:net_kernel, :disconnect, []})
      list_nodes_mfa = Keyword.get(spec, :list_nodes, {:erlang, :nodes, [:connected]})
      opts           = Keyword.get(spec, :child_spec, [])
      worker_args = [[
        topology: topology,
        connect: connect_mfa,
        disconnect: disconnect_mfa,
        list_nodes: list_nodes_mfa,
        config: config
      ]]
      worker(strategy, worker_args, opts)
    end)
  end

  defp filter_for_applied_topologies(_, nil), do: true
  defp filter_for_applied_topologies({topology, _spec}, applied_topologies), do: topology in applied_topologies
end
