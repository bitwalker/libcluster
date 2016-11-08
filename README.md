# libcluster

[![Hex.pm Version](http://img.shields.io/hexpm/v/libcluster.svg?style=flat)](https://hex.pm/packages/libcluster)

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
  - multicast UDP gossip, using a configurable port/multicast address,
  - the Kubernetes API, via a configurable pod selector and node basename.
- provide your own clustering strategies (e.g. an EC2 strategy, etc.)
- provide your own topology plumbing (e.g. something other than standard Erlang distribution)

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
      # A list of options for the supervisor child spec
      # of the selected strategy. Optional
      opts: [restart: :transient]
    ]
  ]
```


## Clustering

You have three choices with regards to cluster management out of the box. You can use the built-in Erlang tooling for connecting
nodes, by setting `strategy: Cluster.Strategy.Epmd` in the config. If set to `Cluster.Strategy.Gossip` it will make use of
the multicast gossip protocol to dynamically form a cluster. If set to `Cluster.Strategy.Kubernetes`, it will use the
Kubernetes API to query endpoints based on a basename and label selector, using the token and namespace injected into
every pod; once it has a list of endpoints, it uses that list to form a cluster, and keep it up to date.

You can provide your own clustering strategy by setting `strategy: MyApp.Strategy` where `MyApp.Strategy` implements the
`Cluster.Strategy` behaviour, which currently consists of exporting a `start_link/1` callback. You don't necessarily have
to start a process as part of your strategy, but since it's very likely you will need to maintain some state, designing your
strategy as an OTP process (i.e. `GenServer`) is the ideal method, however any valid OTP process will work. `libcluster` starts
the strategy process as part of it's supervision tree.

If you do not wish to use the default Erlang distribution protocol, you may provide an alternative means of connecting/
disconnecting nodes via the `connect` and `disconnect` configuration options. They take a `{module, fun, args}` tuple,
and append the node name being targeted to the `args` list. How to implement distribution in this way is left as an
exercise for the reader, but I recommend taking a look at the [Firenest](https://github.com/phoenixframework/firenest) project
currently under development. By default, the Erlang distribution is used.

### Clustering Strategies

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

## License

MIT
