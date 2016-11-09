# This file is provided as an example of how to configure libcluster in your own apps
use Mix.Config

config :libcluster,
  # You can start clustering for one or more topologies.
  topologies: [
    example: [
      # The selected clustering strategy. Required.
      strategy: Cluster.Strategy.Epmd,
      # Options for the provided strategy. Optional.
      config: [],
      # The function to use for connecting nodes. The node
      # name will be appended to the argument list. Optional
      connect: {:net_kernel, :connect, []},
      # The function to use for disconnecting nodes. The node
      # name will be appended to the argument list. Optional
      disconnect: {:net_kernel, :disconnect, []},
      # A list of options for the supervisor child spec
      # of the selected strategy. Optional
      child_spec: []
    ]
  ]
