defmodule Cluster.App do
  @doc false
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Cluster.Events, []),
      Cluster.Strategy.spec()
    ]

    opts = [strategy: :one_for_one, name: Cluster.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
