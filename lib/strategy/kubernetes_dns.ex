defmodule Cluster.Strategy.Kubernetes.DNS do
  @moduledoc """
  This clustering strategy works by loading all your Erlang nodes (within Pods) in the current [Kubernetes
  namespace](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/). 
  It will fetch the addresses of all pods under a shared headless service and attempt to connect.
  It will continually monitor and update its connections every 5s.

  It assumes that all Erlang nodes were launched under a base name, are using longnames,
  and are unique based on their FQDN, rather than the base hostname.
  In other words, by default it uses node names given by the following function:

      fn application_name, ip ->
        :"\#{application_name}@\#{ip}"
      end

  An example configuration is below:


      config :libcluster,
        topologies: [
          k8s_example: [
            strategy: #{__MODULE__},
            config: [
              service: "myapp-headless",
              application_name: "myapp",
              polling_interval: 10_000,  # optional
              node_naming: [MyModule, :my_node_naming, [extra_arg]]  # optional
            ]
          ]
        ]

  You can also use DNS based naming by passing your own custom function in the
  `node_naming` option under `config`.
  For example, to be able to establish a remote shell and run observer in a running
  system, some people might think in a few tricks involving forwarding BEAM ports
  and changing the dev machine's `/etc/hosts` (a workaround the fact the dev machine
  is usually not connected to the internal Kubernetes network).
  Assuming that they are using regular Deployment objects (no StatefulSet or
  hostname configuration), that would require a custom naming compatible to Kubernetes DNS,
  similar to the following:

      @spec my_node_naming(String.t(), String.t()) :: node()
      def my_node_naming(application_name, ip) do
        :"\#{application_name}@\#{String.replace(ip, ".", "-")}.default.pod.cluster.local"
      end

  Of course, to use a custom naming schema, please make sure to change the
  BEAM arguments accordingly on the release configuration
  (See `Cluster.Strategy.Kubernetes` for an example).

  Please notice that when using configuration files the `node_naming` option is
  better given as `[module(), function_name :: atom(), extra_args :: [any()]]`,
  since this kind of file is compiled into plain Erlang terms and therefore
  don't support anonymous functions. In the case a list is provided, it will be
  invoked via `Kernel.apply/3`, and the `extra_args` will be appended to the
  application name and IP. Two-argument anonymous functions can be used
  normally when passing options inline, directly to the supervisor.
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

    %State{state | meta: new_nodelist}
  end

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    app_name = Keyword.fetch!(config, :application_name)
    service = Keyword.fetch!(config, :service)
    resolver = Keyword.get(config, :resolver, &:inet_res.getbyname(&1, :a))
    node_naming = Keyword.get(config, :node_naming, &default_node_naming/2)

    cond do
      app_name != nil and service != nil ->
        headless_service = to_charlist(service)

        case resolver.(headless_service) do
          {:ok, {:hostent, _fqdn, [], :inet, _value, addresses}} ->
            parse_response(addresses, app_name, node_naming)

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

  @doc "Assumes the BEAM node uses a long name composed by the app name and the IP."
  @spec default_node_naming(String.t(), String.t()) :: node()
  def default_node_naming(app_name, ip) do
    :"#{app_name}@#{ip}"
  end

  defp parse_response(addresses, app_name, [module, function, extra_args])
       when is_atom(module)
       when is_atom(function)
       when is_list(extra_args) do
    parse_response(addresses, app_name, &apply(module, function, [&1, &2 | extra_args]))
  end

  defp parse_response(addresses, app_name, node_naming) do
    addresses
    |> Enum.map(&:inet_parse.ntoa(&1))
    |> Enum.map(&to_string/1)
    |> Enum.map(&node_naming.(app_name, &1))
  end
end
