# libcluster

[![Hex.pm Version](http://img.shields.io/hexpm/v/libcluster.svg?style=flat)](https://hex.pm/packages/libcluster)
[![Build Status](https://travis-ci.org/bitwalker/libcluster.svg?branch=master)](https://travis-ci.org/bitwalker/libcluster)

This library provides a mechanism for automatically forming clusters of Erlang nodes, with
either static or dynamic node membership. It provides a publish/subscribe mechanism for cluster
events so that you can easily be notified when cluster members join or leave, and provides a
pluggable "strategy" system, with multicast UDP gossip, Kubernetes, and EPMD strategies all provided
out of the box.

View the docs [here](https://hexdocs.pm/libcluster).

## Features

- automatic cluster formation/healing
- choice of multiple clustering strategies out of the box:
  - standard Distributed Erlang facilities (i.e. epmd)
  - Distributed Erlang via a `.hosts.erlang` file
  - multicast UDP gossip, using a configurable port/multicast address,
  - the Kubernetes API, via a configurable label selector and node basename.
  - the [Rancher Metadata API][rancher-api]
- provide your own clustering strategies (e.g. an EC2 strategy, etc.)
- provide your own topology plumbing (e.g. something other than standard Erlang distribution)

## Installation

```elixir
defp deps do
  [{:libcluster, "~> 2.1"}]
end
```

## An example configuration

The following will help you understand the more descriptive text below. The configuration
for libcluster can also be described as a spec for the clustering topologies and strategies
which will be used.

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
      connect: {:net_kernel, :connect, []},
      # The function to use for disconnecting nodes. The node
      # name will be appended to the argument list. Optional
      disconnect: {:net_kernel, :disconnect, []},
      # The function to use for listing nodes.
      # This function must return a list of node names. Optional
      list_nodes: {:erlang, :nodes, [:connected]},
      # A list of options for the supervisor child spec
      # of the selected strategy. Optional
      child_spec: [restart: :transient]
    ]
  ]
```


## Clustering

You have five choices with regards to cluster management out of the box. You can use the built-in Erlang tooling for connecting
nodes, by setting `strategy: Cluster.Strategy.Epmd` in the config. You can use a .hosts.erlang file by setting
`strategy: Cluster.Strategy.ErlangHosts` If set to `Cluster.Strategy.Gossip` it will make use of the multicast gossip protocol
to dynamically form a cluster. If set to `Cluster.Strategy.Kubernetes`, it will use the Kubernetes API to query endpoints based
on a basename and label selector, using the token and namespace injected into every pod; once it has a list of endpoints, it
uses that list to form a cluster, and keep it up to date. If set to `Cluster.Strategy.Rancher` it uses the
[Rancher Metadata API][rancher-api] to form a cluster of nodes, from containers running under the same service.

You can provide your own clustering strategy by setting `strategy: MyApp.Strategy` where `MyApp.Strategy` implements the
`Cluster.Strategy` behaviour, which currently consists of exporting a `start_link/1` callback. You don't necessarily have
to start a process as part of your strategy, but since it's very likely you will need to maintain some state, designing your
strategy as an OTP process (i.e. `GenServer`) is the ideal method, however any valid OTP process will work. `libcluster` starts
the strategy process as part of it's supervision tree.

If you do not wish to use the default Erlang distribution protocol, you may provide an alternative means of connecting/
disconnecting nodes via the `connect` and `disconnect` configuration options, if not using Erlang distribution you must provide a `list_nodes` implementation as well.
They take a `{module, fun, args}` tuple, and append the node name being targeted to the `args` list. How to implement distribution in this way is left as an
exercise for the reader, but I recommend taking a look at the [Firenest](https://github.com/phoenixframework/firenest) project
currently under development. By default, the Erlang distribution is used.

### Clustering Strategies

The `ErlangHosts` strategy relies on having a `.hosts.erlang` file in one of the following locations as specified in
http://erlang.org/doc/man/net_adm.html#files:

 > File `.hosts.erlang` consists of a number of host names written as Erlang terms. It is looked for in the current work
 > directory, the user's home directory, and $OTP_ROOT (the root directory of Erlang/OTP), in that order.

## Example:

```erlang
'super.eua.ericsson.se'.
'renat.eua.ericsson.se'.
'grouse.eua.ericsson.se'.
'gauffin1.eua.ericsson.se'.
^ (new line)
```

This can be configured using the following settings:

```elixir
config :libcluster,
  topologies: [
    erlang_hosts_example: [
      strategy: Cluster.Strategy.ErlangHosts]]
```


The gossip protocol works by multicasting a heartbeat via UDP. The default configuration listens on all host interfaces,
port 45892, and publishes via the multicast address `230.1.1.251`. These parameters can all be changed via the
following config settings:

```elixir
config :libcluster,
  topologies: [
    gossip_example: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: {0,0,0,0},
        multicast_addr: {230,1,1,251},
        # a TTL of 1 remains on the local network,
        # use this to change the number of jumps the
        # multicast packets will make
        multicast_ttl: 1]]]
```

Debug is deactivated by default for this clustering strategy, but it can be easily activated by configuring the application:

```
use Mix.Config

config :libcluster,
  debug: true
```

All the checks are done at runtime, so you can flip the debug level without being forced to shutdown your node.

The Kubernetes strategy works by querying the Kubernetes API for all endpoints in the same namespace which match the provided
selector, and getting the container IPs associated with them. Once all of the matching IPs have been found, it will attempt to
establish node connections using the format `<kubernetes_node_basename>@<endpoint ip>`. You must make sure that your nodes are
configured to use longnames, that the hostname matches the `kubernetes_node_basename` setting, and that the domain matches the
IP address. Configuration might look like so:

```elixir
config :libcluster,
  topologies: [
    k8s_example: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        kubernetes_selector: "app=myapp",
        kubernetes_node_basename: "myapp"]]]
```

And in vm.args:

```
-name myapp@10.128.0.9
-setcookie test
```

The Rancher strategy follows the steps of the Kubernetes one. It queries the [Rancher Metadata API][rancher-api] for the
IPs associated with the running containers of the specified stack.
You must make sure that your nodes are configured to use longnames like :"<name>@<ip>" where the `name` must be the same
as the `node_basename` config option of the topology and the `ip` must match the one assigned to the container of the
node by Rancher.

Strategy supports two types of stack specification:

```elixir
config :libcluster,
  topologies: [
    rancher_example: [
      strategy: Cluster.Strategy.Rancher,
      config: [
        node_basename: "myapp",
        stack: :self]]]
```
Provides IPs associated with the running containers of the service that the node making the HTTP request belongs to.

```elixir
config :libcluster,
  topologies: [
    rancher_example: [
      strategy: Cluster.Strategy.Rancher,
      config: [
        node_basename: "myapp"
        stack: "front-api",
        service: "api"]]]
```
Allows to specify a stack and a service to query for cluster nodes.

### Third-Party Clustering Strategies

- [libcluster_ec2](https://github.com/kyleaa/libcluster_ec2) - EC2 clustering strategy based on tags
- [libcluster_consul](https://github.com/arcz/libcluster_consul) - Consul clustering strategy

## License

MIT

[rancher-api]: http://rancher.com/docs/rancher/latest/en/rancher-services/metadata-service/
