defmodule Cluster.Strategy.Kubernetes.DNS do
  @default_polling_interval 5_000

  @moduledoc """
  This clustering strategy works by fetching IP addresses with the help of a headless service in
  current Kubernetes namespace.

  > This strategy requires exposing pods by a headless service.
  > If you want to avoid that, you could use `Cluster.Strategy.Kubernetes`.

  It assumes that all Erlang nodes are using longnames - `<basename>@<ip>`:

  + all nodes are using the same `<basename>`
  + all nodes are using unique `<ip>`

  In `<basename>@<ip>`:

  + `<basename>` would be the value configured by `:application_name` option.
  + `<ip>` would be the value which is controlled by following options:
     - `:service`
     - `:resolver`

  ## Getting `<basename>`

  As said above, the basename is configured by `:application_name` option.

  Just one thing to keep in mind - when building an OTP release, make sure that the name of the OTP
  release matches the name configured by `:application_name`.

  ## Getting `<ip>`

  It will fetch IP addresses of all pods under a headless service and attempt to connect.

  ## Setup

  Getting this strategy to work requires:

  1. exposing pod IP from Kubernetes to the Erlang node.
  2. setting a headless service for the pods
  3. setting the name of Erlang node according to the exposed information

  First, expose required information from Kubernetes as environment variables of Erlang node:

      # deployment.yaml
      env:
      - name: POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP

  Second, set a headless service for the pods:

      # deployment.yaml
      apiVersion: v1
      kind: Service
      metadata:
        name: myapp-headless
      spec:
        selector:
          app: myapp
        type: ClusterIP
        clusterIP: None

  Then, set the name of Erlang node by using the exposed environment variables. If you use mix releases, you
  can configure the required options in `rel/env.sh.eex`:

      # rel/env.sh.eex
      export RELEASE_DISTRIBUTION=name
      export RELEASE_NODE=<%= @release.name %>@${POD_IP}

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
              polling_interval: 10_000
            ]
          ]
        ]

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

    %State{state | meta: new_nodelist}
  end

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    app_name = Keyword.fetch!(config, :application_name)
    service = Keyword.fetch!(config, :service)
    resolver = Keyword.get(config, :resolver, &:inet_res.getbyname(&1, :a))

    cond do
      app_name != nil and service != nil ->
        headless_service = to_charlist(service)

        case resolver.(headless_service) do
          {:ok, {:hostent, _fqdn, [], :inet, _value, addresses}} ->
            parse_response(addresses, app_name)

          {:error, reason} ->
            error(topology, "lookup against #{service} failed: #{inspect(reason)}")
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
    |> Enum.map(&:inet_parse.ntoa(&1))
    |> Enum.map(&"#{app_name}@#{&1}")
    |> Enum.map(&String.to_atom(&1))
  end
end
