defmodule Cluster.Strategy.Rancher do
  @moduledoc """
  This clustering strategy is specific to the Rancher container platform.
  It works by querying the platform's metadata API for containers specified in the
  config and attempts to connect them.
  (see: http://rancher.com/docs/rancher/latest/en/rancher-services/metadata-service/)

  It assumes that all nodes share a base name and are using longnames of the form
  `<basename>@<ip>` where the `<ip>` is unique for each node.

  A way to assign a name to a node on boot in an app running as a Distillery release is:

  Create a wrapper script which will interpolate the current ip of the container.

  ```sh
  #!/bin/sh

  export CONTAINER_IP="$(hostname -i | cut -f1 -d' ')"
  export REPLACE_OS_VARS=true
  export BASENAME=myapp

  /app/bin/app "$@"
  ```

  ```
  # vm.args
  -name ${BASENAME}@${CONTAINER_IP}
  ```

  An example configuration for querying the platform's metadata API for containers belonging to
  the same service as the node is below:

      config :libcluster,
        topologies: [
          rancher_example: [
            strategy: #{__MODULE__},
            config: [
              node_basename: "myapp",
              polling_interval: 10_000,
              service: :self]]]

  Strategy also supports querying a specified stack and a service:

    config: [
      node_basename: "myapp",
      stack: "front-api",
      service: "api"]

  """

  use GenServer
  import Cluster.Logger

  alias Cluster.Strategy
  alias Cluster.Strategy.State

  @default_polling_interval 5_000
  @rancher_metadata_base_url "http://rancher-metadata"
  @headers [{'accept', 'application/json'}]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.fetch!(opts, :config),
      meta: Keyword.get(opts, :meta, MapSet.new([]))
    }

    {:ok, load(state)}
  end

  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end

  def handle_info(:load, %State{} = state) do
    {:noreply, load(state)}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp load(
         %State{
           topology: topology,
           connect: connect,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state
       ) do
    new_nodelist = state |> get_nodes() |> MapSet.new()
    added = MapSet.difference(new_nodelist, state.meta)
    removed = MapSet.difference(state.meta, new_nodelist)

    new_nodelist =
      case Strategy.disconnect_nodes(
             topology,
             disconnect,
             list_nodes,
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
      case Strategy.connect_nodes(
             topology,
             connect,
             list_nodes,
             MapSet.to_list(added)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    Process.send_after(self(), :load, polling_interval(state))

    %{state | :meta => new_nodelist}
  end

  defp polling_interval(%{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{config: config} = state) do
    get_node_ips(
      Keyword.fetch(config, :node_basename),
      Keyword.fetch(config, :stack),
      Keyword.fetch(config, :service),
      state
    )
  end

  defp get_node_ips({:ok, app_name}, _stack, {:ok, :self}, state) do
    parse_ips("latest/self/service", app_name, state)
  end

  defp get_node_ips({:ok, app_name}, {:ok, stack}, {:ok, service}, state)
       when is_binary(app_name) and is_binary(stack) and app_name != "" and stack != "" and
              is_binary(service) and service != "" do
    parse_ips("latest/stacks/#{stack}/services/#{service}", app_name, state)
  end

  defp get_node_ips({:ok, wrong_app_name}, {:ok, wrong_stack}, {:ok, wrong_service}, %State{
         topology: topology
       }) do
    warn(
      topology,
      "rancher strategy is selected, but configuration is invalid, please check: #{
        inspect(%{node_basename: wrong_app_name, stack: wrong_stack, service: wrong_service})
      }"
    )

    []
  end

  defp get_node_ips(:error, {:ok, _stack}, {:ok, _service}, %State{topology: topology}) do
    warn(topology, "rancher strategy is selected, but :node_basename is missing")
    []
  end

  defp get_node_ips({:ok, _app_name}, :error, _service, %State{topology: topology}) do
    warn(topology, "rancher strategy is selected, but :stack is missing")
    []
  end

  defp get_node_ips({:ok, _app_name}, {:ok, _stack}, :error, %State{topology: topology}) do
    warn(topology, "rancher strategy is selected, but :service is missing")
    []
  end

  defp get_node_ips(:error, :error, :error, %State{topology: topology}) do
    warn(topology, "missing :node_basename, :stack & :service for rancher strategy")
    []
  end

  defp parse_ips(endpoint, app_name, %State{topology: topology, config: config}) do
    base_url = Keyword.get(config, :rancher_metadata_base_url, @rancher_metadata_base_url)

    case :httpc.request(:get, {'#{base_url}/#{endpoint}', @headers}, [], []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        parse_response(Jason.decode!(body), app_name)

      {:ok, {{_version, code, status}, _headers, body}} ->
        warn(
          topology,
          "cannot query Rancher Metadata API (#{code} #{status}): #{inspect(body)}"
        )

        []

      {:error, reason} ->
        error(topology, "request to Rancher Metadata API failed!: #{inspect(reason)}")
        []
    end
  end

  defp parse_response(resp, app_name) when is_list(resp) do
    Enum.flat_map(resp, &parse_response(&1, app_name))
  end

  defp parse_response(resp, app_name) when is_map(resp) do
    case resp do
      %{"containers" => containers} ->
        Enum.map(containers, fn %{"ips" => [ip | _]} -> :"#{app_name}@#{ip}" end)

      _ ->
        []
    end
  end

  defp parse_response(_, _), do: []
end
