defmodule Cluster.Strategy.MultiRancher do
  @moduledoc """
  This clustering strategy is specific to the Rancher container platform.
  It works by querying the platform's metadata API for containers belonging to
  specified stack and service and attempts to connect them.
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
              polling_interval: 5_000,
              stacks: [
                [name: "front-api", services: ["api"]],
                [name: "user-service", services: ["service"]]
              ]
            ]
          ]
        ]
  """

  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State
  alias Cluster.Strategy

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

    Process.send_after(
      self(),
      :load,
      Keyword.get(state.config, :polling_interval, @default_polling_interval)
    )

    %{state | :meta => new_nodelist}
  end

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config} = state) do
    case [Keyword.fetch(config, :node_basename), Keyword.fetch(config, :stacks)] do
      [{:ok, app_name}, {:ok, stacks}]
      when is_binary(app_name) and is_list(stacks) and app_name != "" and
             length(stacks) != 0 ->
        get_node_ips(app_name, stacks, state)

      [{:ok, app_name}, {:ok, stacks}] ->
        warn(
          topology,
          "rancher strategy is selected, but :node_basename or :stacks is invalid #{
            inspect(%{node_basename: app_name, stacks: stacks})
          }"
        )

        []

      [{:ok, _app_name}, :error] ->
        warn(
          topology,
          "rancher strategy is selected, but :stacks is missing"
        )

        []

      [:error, {:ok, _stacks}] ->
        warn(
          topology,
          "rancher strategy is selected, but :node_basename is missing"
        )

        []

      [:error, :error] ->
        warn(topology, "missing :node_basename or :stacks for rancher strategy")
        []
    end
  end

  defp get_node_ips(app_name, stacks, state) do
    stacks
    |> Enum.flat_map(fn stack ->
      Enum.map(stack[:services], &"latest/stacks/#{stack[:name]}/services/#{&1}")
    end)
    |> Enum.flat_map(&parse_ips(&1, app_name, state))
  end

  defp parse_ips(endpoint, app_name, %State{topology: topology, config: config}) do
    base_url = Keyword.get(config, :rancher_metadata_base_url, @rancher_metadata_base_url)

    case :httpc.request(:get, {'#{base_url}/#{endpoint}', @headers}, [], []) do
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
  end

  defp parse_response(app_name, resp) when is_list(resp) do
    Enum.flat_map(resp, &parse_response_item(&1, app_name))
  end

  defp parse_response(app_name, resp) when is_map(resp) do
    parse_response_item(resp, app_name)
  end

  defp parse_response(_, _), do: []

  defp parse_response_item(resp_item, app_name) do
    case resp_item do
      %{"containers" => containers} ->
        Enum.map(containers, fn %{"ips" => [ip | _]} -> :"#{app_name}@#{ip}" end)

      _ ->
        []
    end
  end
end
