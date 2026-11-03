defmodule Cluster.Strategy.Kubernetes.DNSSRV do
  @default_polling_interval 5_000

  @moduledoc """
  This clustering strategy discovers node hostnames from SRV records for a headless Service.
  The example below uses a StatefulSet to give Pods stable hostnames.

  > This strategy requires per-Pod DNS identities exposed by a headless Service.
  > A StatefulSet provides the stable hostnames used in this example.
  > If you want to avoid that, you could use `Cluster.Strategy.Kubernetes.DNS`.

  It assumes that all Erlang nodes are using longnames - `<basename>@<domain>`:

  + all nodes are using the same `<basename>`
  + all nodes are using unique `<domain>`

  In `<basename>@<domain>`:

  + `<basename>` would be the value configured by `:application_name` option.
  + `<domain>` would be the value which is controlled by following options:
     - `:service`
     - `:namespace`
     - `:resolver`

  ## Getting `<basename>`

  As said above, the basename is configured by `:application_name` option.

  The basename of each peer's running node must match `:application_name`. The Mix release name is
  only the default basename in the examples below; an explicit `RELEASE_NODE` can override it.
  See [Kubernetes node naming](readme.html#kubernetes-node-naming) for runtime release configuration
  and troubleshooting long names, peer identities and connectivity.

  ## Getting `<domain>`

  > For more information, see the kubernetes stateful-application [documentation](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/#using-stable-network-identities)

  ## Setup

  Getting this strategy to work requires:

  1. giving each Pod a hostname matching its SRV target (a StatefulSet supplies stable identities)
  2. exposing above StatefulSet by a headless service (otherwise, the SRV query won't work as expected)
  3. setting the name of Erlang node according to hostname of pods

  First, deploying pods as a StatefulSet which is exposed by a headless service. And here is an
  example of a corresponding Kubernetes definition:

  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: "myapp-headless"
    labels:
      app: myapp
  spec:
    ports:
    - port: 4000
      name: web
    clusterIP: None
    selector:
      app: myapp
  ---
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: myapp
  spec:
    serviceName: "myapp-headless"
    replicas: 2
    selector:
      matchLabels:
        app: myapp
    template:
      metadata:
        labels:
          app: myapp
      spec:
        containers:
        - name: myapp
          image: myapp:v1.0.0
          imagePullPolicy: Always
          ports:
          - containerPort: 4000
            name: http
            protocol: TCP
  ```

  Then, set the name of Erlang node by using the hostname of pod. If you use mix releases, you
  can configure the required options in `rel/env.sh.eex`:

      # rel/env.sh.eex
      export RELEASE_DISTRIBUTION=name
      export RELEASE_NODE="<%= @release.name %>@$(hostname -f)"

  ## Polling Interval

  The default interval to sync topologies is `#{@default_polling_interval}`
  (#{div(@default_polling_interval, 1000)} seconds). You can configure it with `:polling_interval` option.

  ## An example configuration

      config :libcluster,
        topologies: [
          erlang_nodes_in_k8s: [
            strategy: #{__MODULE__},
            config: [
              service: "_web._tcp.myapp-headless",
              application_name: "myapp",
              namespace: "default",
              polling_interval: 10_000
            ]
          ]
        ]

  ## Select the SRV query

  For the Service's named `web` TCP port, set `service: "_web._tcp.myapp-headless"`.
  The strategy appends the namespace and `svc.<cluster-domain>`; with namespace `default`
  and the default domain, the query is `_web._tcp.myapp-headless.default.svc.cluster.local.`.
  Do not pass the full FQDN as `:service`. Set `CLUSTER_DOMAIN` if your cluster uses another domain.
  `StatefulSet.spec.serviceName` remains `myapp-headless`, without the port/protocol prefix.

  Kubernetes specifies SRV names as `_port-name._protocol.service.namespace.svc.cluster-domain`.
  A headless Service returns per-Pod targets; a normal ClusterIP Service returns its Service name.
  See [Kubernetes DNS records](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#srv-records).
  Bare Service SRV queries may work with some DNS implementations; existing configurations remain
  accepted, but named-port queries avoid relying on that extension. This is not a CoreDNS-only strategy.

  Only the SRV target contributes to `application_name@target`. The SRV port, priority and weight
  do not select the Erlang distribution listener; the default distribution uses EPMD for that.
  An HTTP port in the discovery Service therefore does not make distribution use HTTP.

  ## Check the SRV targets

  From an application Pod, inspect the selected Service and the exact query:

  ```sh
  kubectl get service myapp-headless -n default -o yaml
  kubectl get statefulset myapp -n default -o yaml
  dig +short SRV _web._tcp.myapp-headless.default.svc.cluster.local.
  ```

  Expected targets include `myapp-0.myapp-headless.default.svc.cluster.local.` and
  `myapp-1.myapp-headless.default.svc.cluster.local.`, not just the Service FQDN. The final dot
  in `dig` output denotes an absolute DNS name. Compare the actual Erlang resolver result and
  libcluster's logged target with the peer's `Node.self()`; do not append dots to Erlang node names
  as a workaround. Check the Service selector, `clusterIP: None`, named port/protocol,
  StatefulSet `serviceName`, namespace, cluster domain and published endpoint readiness.

  For example, `myapp@myapp-headless.default.svc.cluster.local` is not the same node identity as
  `myapp@myapp-0.myapp-headless.default.svc.cluster.local`, even if both hostnames reach a Pod.
  Use the [node naming checks](readme.html#kubernetes-node-naming) and attempt `Node.connect/1`
  with exactly the target libcluster logs, from the running application node.

  Once identities match, check EPMD and the distribution listener from each peer. To bound the
  listener to TCP 9100 in a Mix release, add this to `rel/env.sh.eex`:

  ```sh
  case "$RELEASE_COMMAND" in
    start*|daemon*)
      export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"
      ;;
  esac
  ```

  Apply the bound only to application startup, so `rpc` and remote-console helper VMs can use
  their own ports. Permit TCP 4369 (default EPMD) and 9100 between Pods in network policies and
  firewalls. In a mesh, check interception, authorization and TLS policy for both connections;
  Erlang distribution is TCP, not HTTP. Configure the actual distribution ports as opaque TCP
  according to [Istio protocol selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/).
  If DNS, identity and direct connectivity agree, reproduce in a disposable deployment with
  and without sidecars before attributing the remaining failure to Istio. No mesh bypass or
  global TLS-policy change is required by this strategy.

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @impl true
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{meta: nil} = state]) do
    init([%State{state | :meta => MapSet.new()}])
  end

  def init([%State{} = state]) do
    {:ok, load(state), 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end

  def handle_info(:load, state) do
    {:noreply, load(state)}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp load(%State{topology: topology, meta: meta} = state) do
    new_nodelist = MapSet.new(get_nodes(state))
    removed = MapSet.difference(meta, new_nodelist)

    new_nodelist =
      case Cluster.Strategy.disconnect_nodes(
             topology,
             state.disconnect,
             state.list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      case Cluster.Strategy.connect_nodes(
             topology,
             state.connect,
             state.list_nodes,
             MapSet.to_list(new_nodelist)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    Process.send_after(
      self(),
      :load,
      polling_interval(state)
    )

    %State{state | :meta => new_nodelist}
  end

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    app_name = Keyword.fetch!(config, :application_name)
    service = Keyword.fetch!(config, :service)
    namespace = Keyword.fetch!(config, :namespace)

    service_k8s_path =
      "#{service}.#{namespace}.svc.#{System.get_env("CLUSTER_DOMAIN", "cluster.local.")}"

    resolver = Keyword.get(config, :resolver, &:inet_res.getbyname(&1, :srv))

    cond do
      app_name != nil and service != nil ->
        headless_service = to_charlist(service_k8s_path)

        case resolver.(headless_service) do
          {:ok, {:hostent, _, _, :srv, _count, addresses}} ->
            parse_response(addresses, app_name)

          {:error, reason} ->
            error(
              topology,
              "#{inspect(headless_service)} : lookup against #{service} failed: #{inspect(reason)}"
            )

            []
        end

      app_name == nil ->
        warn(
          topology,
          "kubernetes.DNS strategy is selected, but :application_name is not configured!"
        )

        []

      service == nil ->
        warn(topology, "kubernetes strategy is selected, but :service is not configured!")
        []

      :else ->
        warn(topology, "kubernetes strategy is selected, but is not configured!")
        []
    end
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  defp parse_response(addresses, app_name) do
    addresses
    |> Enum.map(&:erlang.list_to_binary(elem(&1, 3)))
    |> Enum.map(&"#{app_name}@#{&1}")
    |> Enum.map(&String.to_atom(&1))
  end
end
