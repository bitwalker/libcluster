defmodule Cluster.Strategy.EC2 do
  @moduledoc """
  This clustering strategy is specific to the AWS EC2.
  It works by querying the AWS EC2 API and all instances related to the same in the configuration
  specified security group and attempts to connect them.

  It assumes that all nodes share a base name and are using longnames of the form
  `<basename@<ip>` where the `<ip>` is unique for each node.

  A way to assign a name and ip to a node on boot in an app running as a Distillery release is:

  Create a pref_configure_hook script which will query the EC2 meta data for the current ip of the instance.

  ```sh
  NODE_IP=$(curl -s --url http://169.254.169.254/latest/meta-data/local-ipv4 --retry 3 --max-time 5)
  if [[ -n "${NODE_IP}" ]]; then
    export NODE_NAME="${NODE_BASE_NAME}@${NODE_IP}"
  fi
  ```

  ```
  # vm.args
  -name ${NODE_NAME}
  -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9200
  ```

  An example configuration is below:


      config :libcluster,
        topologies:
        [
          ec2_example:
          [
            strategy: #{__MODULE__},
            config:
            [
              region: "eu-central-1",
              security_group_name: "security-group-name",
              node_basename: "app",
              polling_interval: 10_000
            ]
          ]
        ]
  """

  use GenServer
  use Cluster.Strategy
  import Cluster.Logger
  import SweetXml

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
    case Keyword.fetch!(config, :security_group_name) do
      security_group_name when is_binary(security_group_name) and security_group_name != "" ->
        ExAws.EC2.describe_instances([filters: ["instance.group-name": [security_group_name]]])
        |> ExAws.request!(region: Keyword.fetch!(config, :region))
        |> parse_response(Keyword.fetch!(config, :node_basename))
      security_group_name ->
        warn topology, "ec2 strategy is selected, but :security_group_name is invalid, got: #{inspect security_group_name}"
        []
    end
  end

  defp parse_response(%{body: xml}, app_name) do
    xml
    |> xpath(~x"//instancesSet/item/privateIpAddress/text()"sl)
    |> Enum.map(fn(ip) ->
        :"#{app_name}@#{ip}"
    end)
  end
end