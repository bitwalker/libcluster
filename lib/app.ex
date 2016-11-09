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
    specs = Application.get_env(:libcluster, :topologies, [])
    for {topology, spec} <- specs do
      strategy       = Keyword.fetch!(spec, :strategy)
      config         = Keyword.get(spec, :config, [])
      connect_mfa    = Keyword.get(spec, :connect, {:net_kernel, :connect, []})
      disconnect_mfa = Keyword.get(spec, :disconnect, {:net_kernel, :disconnect, []})
      opts           = Keyword.get(spec, :child_spec, [])
      worker_args = [[
        topology: topology,
        connect: connect_mfa,
        disconnect: disconnect_mfa,
        config: config
      ]]
      worker(strategy, worker_args, opts)
    end
  end
end
