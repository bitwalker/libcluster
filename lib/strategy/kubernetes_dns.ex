defmodule Cluster.Strategy.Kubernetes.DNS do
  @moduledoc """
  This clustering strategy works by loading all your Erlang nodes (within Pods) in the current Kubernetes
  namespace. It will fetch the addresses of all pods under a shared headless service and attempt to connect. 
  It will continually monitor and update its connections every 5s.

  It assumes that all Erlang nodes were launched under a base name, are using longnames, and are unique
  based on their FQDN, rather than the base hostname. In other words, in the following
  longname, `<basename>@<ip>`, `basename` would be the value configured through
  `application_name`.

  An example configuration is below:


      config :libcluster,
        topologies: [
          k8s_example: [
            strategy: #{__MODULE__},
            config: [
              service: "myapp-headless",
              application_name: "myapp",
              polling_interval: 10_000]]]

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.fetch!(opts, :config),
      meta: MapSet.new([])
    }
    {:ok, state, 0}
  end

  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end
  def handle_info(:load, %State{topology: topology, connect: connect, disconnect: disconnect, list_nodes: list_nodes} = state) do
    new_nodelist = MapSet.new(get_nodes(state))
    added        = MapSet.difference(new_nodelist, state.meta)
    removed      = MapSet.difference(state.meta, new_nodelist)
    new_nodelist = case Cluster.Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
                :ok ->
                  new_nodelist
                {:error, bad_nodes} ->
                  # Add back the nodes which should have been removed, but which couldn't be for some reason
                  Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                    MapSet.put(acc, n)
                  end)
              end
    new_nodelist = case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(added)) do
              :ok ->
                new_nodelist
              {:error, bad_nodes} ->
                # Remove the nodes which should have been added, but couldn't be for some reason
                Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                  MapSet.delete(acc, n)
                end)
            end
    Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
    {:noreply, %{state | :meta => new_nodelist}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end



  @spec get_nodes(State.t) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    app_name = Keyword.fetch!(config, :application_name)
    service = Keyword.fetch!(config, :service)
    cond do
      app_name != nil and service != nil ->
        headless_service = service |> Kernel.to_charlist
        case :inet_res.getbyname(headless_service, :a) do
          {:ok, {:hostent, fqdn, [], :inet, value, adresses}} -> 
            parse_response(adresses, app_name)
          {:error, reason} ->
            error topology, "lookup against #{service} failed: #{inspect reason}"
            []
        end
      app_name == nil ->
        warn topology, "kubernetes.DNS strategy is selected, but :application_name is not configured!"
        []
      service == nil ->
        warn topology, "kubernetes strategy is selected, but :service is not configured!"
        []
      :else ->
        warn topology, "kubernetes strategy is selected, but is not configured!"
        []
    end
  end

  defp parse_response(adresses, app_name) do
    adresses 
    |> Enum.map(&(:inet_parse.ntoa(&1))) 
    |> Enum.map(&("#{app_name}@#{&1}")) 
    |> Enum.map(&(String.to_atom(&1)))
  end


end
