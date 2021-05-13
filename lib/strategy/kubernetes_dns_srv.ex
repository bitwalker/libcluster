defmodule Cluster.Strategy.Kubernetes.DNSSRV do
  @moduledoc """
  This clustering strategy works by issuing a SRV query for the kubernetes headless service
  under which the stateful set containing your nodes is running.

  For more information, see the kubernetes stateful-application [documentation](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/#using-stable-network-identities)

  * It will fetch the FQDN of all pods under the headless service and attempt to connect.
  * It will continually monitor and update its connections according to the polling_interval (default 5s)

  The `application_name` is configurable (you may have launched erlang with a different configured name),
  but will in most cases be the name of your application

  An example configuration is below:

      config :libcluster,
        topologies: [
          k8s_example: [
            strategy: #{__MODULE__},
            config: [
              service: "elixir-plug-poc",
              application_name: "elixir_plug_poc",
              polling_interval: 10_000]]]

  An example of how this strategy extracts topology information from DNS follows:

  ```
  bash-5.0# hostname -f
  elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local
  bash-5.0# dig SRV elixir-plug-poc.default.svc.cluster.local

  ; <<>> DiG 9.14.3 <<>> SRV elixir-plug-poc.default.svc.cluster.local
  ;; global options: +cmd
  ;; Got answer:
  ;; WARNING: .local is reserved for Multicast DNS
  ;; You are currently testing what happens when an mDNS query is leaked to DNS
  ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 7169
  ;; flags: qr aa rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 2

  ;; QUESTION SECTION:
  ;elixir-plug-poc.default.svc.cluster.local. IN SRV

  ;; ANSWER SECTION:
  elixir-plug-poc.default.svc.cluster.local. 30 IN SRV 10 50 0 elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local.
  elixir-plug-poc.default.svc.cluster.local. 30 IN SRV 10 50 0 elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local.

  ;; ADDITIONAL SECTION:
  elixir-plug-poc-0.elixir-plug-poc.default.svc.cluster.local. 30 IN A 10.1.0.95
  elixir-plug-poc-1.elixir-plug-poc.default.svc.cluster.local. 30 IN A 10.1.0.96

  ;; Query time: 0 msec
  ;; SERVER: 10.96.0.10#53(10.96.0.10)
  ;; WHEN: Wed Jul 03 11:55:27 UTC 2019
  ;; MSG SIZE  rcvd: 167
  ```

  And here is an example of a corresponding kubernetes statefulset/service definition:

  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: elixir-plug-poc
    labels:
      app: elixir-plug-poc
  spec:
    ports:
    - port: 4000
      name: web
    clusterIP: None
    selector:
      app: elixir-plug-poc
  ---
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: elixir-plug-poc
  spec:
    serviceName: "elixir-plug-poc"
    replicas: 2
    selector:
      matchLabels:
        app: elixir-plug-poc
    template:
      metadata:
        labels:
          app: elixir-plug-poc
      spec:
        containers:
        - name: elixir-plug-poc
          image: binarytemple/elixir_plug_poc
          args:
            - foreground
          env:
            - name: ERLANG_COOKIE
              value: "cookie"
          imagePullPolicy: Always
          ports:
          - containerPort: 4000
            name: http
            protocol: TCP
  ```
  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000

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
