defmodule Cluster.Strategy.Kubernetes.DNSSRV do
  @default_polling_interval 5_000

  @moduledoc """
  This clustering strategy works by issuing a SRV query for the headless service where the StatefulSet
  containing your nodes is running.

  > This strategy requires deploying pods as a StatefulSet which is exposed by a headless service.
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

  Just one thing to keep in mind - when building an OTP release, make sure that the name of the OTP
  release matches the name configured by `:application_name`.

  ## Getting `<domain>`

  > For more information, see the kubernetes stateful-application [documentation](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/#using-stable-network-identities)

  ## Setup

  Getting this strategy to work requires:

  1. deploying pods as a StatefulSet (otherwise, hostname won't set for pods)
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
      export RELEASE_NODE=<%= @release.name %>@$(hostname -f)

  ## Polling Interval

  The default interval to sync topologies is `#{@default_polling_interval}`
  (#{div(@default_polling_interval, 1000)} seconds). You can configure it with `:polling_interval` option.

  ## An example configuration

      config :libcluster,
        topologies: [
          erlang_nodes_in_k8s: [
            strategy: #{__MODULE__},
            config: [
              service: "myapp-headless",
              application_name: "myapp",
              namespace: "default",
              polling_interval: 10_000
            ]
          ]
        ]

  ## An example of how this strategy extracts topology information from DNS

  ```sh
  $ hostname -f
  myapp-1.myapp-headless.default.svc.cluster.local

  # An SRV query for a headless service returns multiple entries
  $ dig SRV myapp-headless.default.svc.cluster.local

  ; <<>> DiG 9.14.3 <<>> SRV myapp-headless.default.svc.cluster.local
  ;; global options: +cmd
  ;; Got answer:
  ;; WARNING: .local is reserved for Multicast DNS
  ;; You are currently testing what happens when an mDNS query is leaked to DNS
  ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 7169
  ;; flags: qr aa rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 2

  ;; QUESTION SECTION:
  ;myapp-headless.default.svc.cluster.local. IN SRV

  ;; ANSWER SECTION:
  myapp-headless.default.svc.cluster.local. 30 IN SRV 10 50 0 myapp-0.myapp-headless.default.svc.cluster.local.
  myapp-headless.default.svc.cluster.local. 30 IN SRV 10 50 0 myapp-1.myapp-headless.default.svc.cluster.local.

  ;; ADDITIONAL SECTION:
  myapp-0.myapp-headless.default.svc.cluster.local. 30 IN A 10.1.0.95
  myapp--1.myapp-headless.default.svc.cluster.local. 30 IN A 10.1.0.96

  ;; Query time: 0 msec
  ;; SERVER: 10.96.0.10#53(10.96.0.10)
  ;; WHEN: Wed Jul 03 11:55:27 UTC 2019
  ;; MSG SIZE  rcvd: 167
  ```

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
