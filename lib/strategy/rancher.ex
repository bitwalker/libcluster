defmodule Cluster.Strategy.Rancher do
  @moduledoc """
  This clustering strategy is specific to the Rancher container platform.
  It works by querying the platform's metadata API for containers belonging to
  the same service as the node and attempts to connect them.
  (see: http://rancher.com/docs/rancher/latest/en/rancher-services/metadata-service/)

  It assumes that all nodes share a base name and are using longnames of the form
  `<basename@<ip>` where the `<ip>` is unique for each node.

  A way to assign a name to a node on boot in an app running as a Distillery release is:

  Create a wrapper script which will interpolate the current ip of the container.

  ```sh
  #!/bin/sh

  export CONTAINER_IP="$(hostname -I | cut -f1 -d' ')"
  export REPLACE_OS_VARS=true

  /app/bin/app "$@"
  ```

  ```
  # vm.args
  -name app@${CONTAINER_IP}
  ```

  An example configuration is below:


      config :libcluster,
        topologies: [
          rancher_example: [
            strategy: #{__MODULE__},
            config: [
              node_basename: "myapp",
              polling_interval: 10_000]]]
  """

  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000
  @rancher_metadata_base_url "http://rancher-metadata"

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{meta: nil} = state]) do
    init([%State{state | :meta => MapSet.new()}])
  end

  def init([%State{} = state]) do
    {:ok, load(state)}
  end

  @impl true
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
    new_nodelist = MapSet.new(get_nodes(state))
    removed = MapSet.difference(state.meta, new_nodelist)

    new_nodelist =
      case Cluster.Strategy.disconnect_nodes(
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
      case Cluster.Strategy.connect_nodes(
             topology,
             connect,
             list_nodes,
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

    Process.send_after(self(), :load, polling_interval(state))

    %{state | :meta => new_nodelist}
  end

  defp polling_interval(%{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    case Keyword.fetch!(config, :node_basename) do
      app_name when is_binary(app_name) and app_name != "" ->
        endpoints_path = "latest/self/service"
        headers = [{'accept', 'application/json'}]

        case :httpc.request(
               :get,
               {'#{@rancher_metadata_base_url}/#{endpoints_path}', headers},
               [],
               []
             ) do
          {:ok, {{_version, 200, _status}, _headers, body}} ->
            parse_response(app_name, Jason.decode!(body))

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

      app_name ->
        warn(
          topology,
          "rancher strategy is selected, but :node_basename is invalid, got: #{inspect(app_name)}"
        )

        []
    end
  end

  defp parse_response(app_name, resp) do
    case resp do
      %{"containers" => containers} ->
        Enum.map(containers, fn %{"ips" => [ip | _]} -> :"#{app_name}@#{ip}" end)

      _ ->
        []
    end
  end
end
