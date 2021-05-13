# libcluster

[![Build Status](https://github.com/bitwalker/libcluster/workflows/elixir/badge.svg?branch=master)](https://github.com/bitwalker/libcluster/actions?query=workflow%3A%22elixir%22+branch%3Amaster)
[![Module Version](https://img.shields.io/hexpm/v/libcluster.svg)](https://hex.pm/packages/libcluster)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/libcluster/)
[![Total Download](https://img.shields.io/hexpm/dt/libcluster.svg)](https://hex.pm/packages/libcluster)
[![License](https://img.shields.io/hexpm/l/libcluster.svg)](https://github.com/bitwalker/libcluster/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/bitwalker/libcluster.svg)](https://github.com/bitwalker/libcluster/commits/master)

This library provides a mechanism for automatically forming clusters of Erlang nodes, with
either static or dynamic node membership. It provides a pluggable "strategy" system, with a variety of strategies
provided out of the box.

You can find supporting documentation [here](https://hexdocs.pm/libcluster).

## Features

- Automatic cluster formation/healing
- Choice of multiple clustering strategies out of the box:
  - Standard Distributed Erlang facilities (e.g. `epmd`, `.hosts.erlang`), which supports IP-based or DNS-based names
  - Multicast UDP gossip, using a configurable port/multicast address,
  - Kubernetes via its metadata API using via a configurable label selector and
    node basename; or alternatively, using DNS.
  - Rancher, via its [metadata API][rancher-api]
- Easy to provide your own custom clustering strategies for your specific environment.
- Easy to use provide your own distribution plumbing (i.e. something other than
  Distributed Erlang), by implementing a small set of callbacks. This allows
  `libcluster` to support projects like
  [Partisan](https://github.com/lasp-lang/partisan).

## Installation

```elixir
defp deps do
  [{:libcluster, "~> MAJ.MIN"}]
end
```

You can determine the latest version by running `mix hex.info libcluster` in
your shell, or by going to the `libcluster` [page on Hex.pm](https://hex.pm/packages/libcluster).

## Usage

It is easy to get started using `libcluster`, simply decide which strategy you
want to use to form a cluster, define a topology, and then start the `Cluster.Supervisor` module in
the supervision tree of an application in your Elixir system, as demonstrated below:

```elixir
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
      # ..other children..
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

The following section describes topology configuration in more detail.

## Example Configuration

You can configure `libcluster` either in your Mix config file (`config.exs`) as
shown below, or construct the keyword list structure manually, as shown in the
previous section. Either way, you need to pass the configuration to the
`Cluster.Supervisor` module in it's start arguments. If you prefer to use Mix
config files, then simply use `Application.get_env(:libcluster, :topologies)` to
get the config that `Cluster.Supervisor` expects.

```elixir
config :libcluster,
  topologies: [
    example: [
      # The selected clustering strategy. Required.
      strategy: Cluster.Strategy.Epmd,
      # Configuration for the provided strategy. Optional.
      config: [hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]],
      # The function to use for connecting nodes. The node
      # name will be appended to the argument list. Optional
      connect: {:net_kernel, :connect_node, []},
      # The function to use for disconnecting nodes. The node
      # name will be appended to the argument list. Optional
      disconnect: {:erlang, :disconnect_node, []},
      # The function to use for listing nodes.
      # This function must return a list of node names. Optional
      list_nodes: {:erlang, :nodes, [:connected]},
    ]
  ]
```

## Strategy Configuration

For instructions on configuring each strategy included with `libcluster`, please
visit the docs on [HexDocs](https://hexdocs.pm/libcluster), and look at the
module doc for the strategy you want to use. The authoritative documentation for
each strategy is kept up to date with the module implementing it.

## Clustering

You have a handful of choices with regards to cluster management out of the box:

- `Cluster.Strategy.Epmd`, which relies on `epmd` to connect to a configured set
  of hosts.
- `Cluster.Strategy.LocalEpmd`, which relies on `epmd` to connect to discovered
  nodes on the local host.
- `Cluster.Strategy.ErlangHosts`, which uses the `.hosts.erlang` file to
  determine which hosts to connect to.
- `Cluster.Strategy.Gossip`, which uses multicast UDP to form a cluster between
  nodes gossiping a heartbeat.
- `Cluster.Strategy.Kubernetes`, which uses the Kubernetes Metadata API to query
  nodes based on a label selector and basename.
- `Cluster.Strategy.Kubernetes.DNS`, which uses DNS to join nodes under a shared
  headless service in a given namespace.
- `Cluster.Strategy.Rancher`, which like the Kubernetes strategy, uses a
  metadata API to query nodes to cluster with.

You can also define your own strategy implementation, by implementing the
`Cluster.Strategy` behavior. This behavior expects you to implement a
`start_link/1` callback, optionally overriding `child_spec/1` if needed. You don't necessarily have
to start a process as part of your strategy, but since it's very likely you will need to maintain some state, designing your
strategy as an OTP process (e.g. `GenServer`) is the ideal method, however any
valid OTP process will work. See the `Cluster.Strategy` module for details on
the callbacks you need to implement and the arguments they receive.

If you do not wish to use the default Erlang distribution protocol, you may provide an alternative means of connecting/
disconnecting nodes via the `connect` and `disconnect` configuration options, if not using Erlang distribution you must provide a `list_nodes` implementation as well.
They take a `{module, fun, args}` tuple, and append the node name being targeted to the `args` list. How to implement distribution in this way is left as an
exercise for the reader, but I recommend taking a look at the [Firenest](https://github.com/phoenixframework/firenest) project
currently under development. By default, `libcluster` uses Distributed Erlang.

### Third-Party Strategies

The following list of third-party strategy implementations is not comprehensive,
but are known to exist.

- [libcluster_ec2](https://github.com/kyleaa/libcluster_ec2) - EC2 clustering strategy based on tags
- [libcluster_consul](https://github.com/team-telnyx/libcluster_consul) - Consul clustering strategy

## Copyright and License

Copyright (c) 2016 Paul Schoenfelder

This library is MIT licensed. See the
[LICENSE.md](https://github.com/bitwalker/libcluster/blob/master/LICENSE.md) for details.

[rancher-api]: http://rancher.com/docs/rancher/latest/en/rancher-services/metadata-service/
