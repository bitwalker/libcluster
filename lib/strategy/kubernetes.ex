defmodule Cluster.Strategy.Kubernetes do
  @moduledoc """
  This clustering strategy works by loading all pods in the current Kubernetes
  namespace with the configured tag. It will fetch the addresses of all pods with
  that tag and attempt to connect. It will continually monitor and update its
  connections every 5s.


  It assumes that all nodes share a base name, are using longnames, and are unique
  based on their FQDN, rather than the base hostname. In other words, in the following
  longname, `<basename>@<domain>`, `basename` would be the value configured in

  <domain> can be either of type :ip (the pod's ip, can be obtained by setting an env
  variable to status.podIP) or :dns, which is the pod's internal A Record.
  This A Record has the format <ip-with-dashes>.<namespace>.pod.cluster.local, e.g
  1-2-3-4.default.pod.cluster.local.

  Getting :ip to work requires a bit fiddling in the container's CMD, for example:

  ```yaml
  # deployment.yaml
  command: ["sh", -c"]
  args: ["POD_A_RECORD"]
  args: ["export POD_A_RECORD=$(echo $POD_IP | sed 's/\./-/g') && /app/bin/app foreground"]
  ```

  ```
  # vm.args
  -name app@<%= "${POD_A_RECORD}.${NAMESPACE}.pod.cluster.local" %>
  ```

  (in an app running as a Distillery release).

  The benefit of using :dns over :ip is that you can establish a remote shell (as well as
  run observer) by using `kubectl port-forward` in combination with some entries in `/etc/hosts`.


  Defaults to :ip.

  An example configuration is below:


      config :libcluster,
        topologies: [
          k8s_example: [
            strategy: #{__MODULE__},
            config: [
              mode: :ip,
              kubernetes_node_basename: "myapp",
              kubernetes_selector: "app=myapp",
              polling_interval: 10_000]]]

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000
  @kubernetes_master    "kubernetes.default.svc.cluster.local"
  @service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

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

  @spec get_token() :: String.t
  defp get_token() do
    path = Path.join(@service_account_path, "token")
    case File.exists?(path) do
      true  -> path |> File.read! |> String.trim()
      false -> ""
    end
  end

  @spec get_namespace() :: String.t
  defp get_namespace() do
    path = Path.join(@service_account_path, "namespace")
    case File.exists?(path) do
      true  -> path |> File.read! |> String.trim()
      false -> ""
    end
  end

  @spec get_nodes(State.t) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    token     = get_token()
    namespace = get_namespace()
    app_name = Keyword.fetch!(config, :kubernetes_node_basename)
    selector = Keyword.fetch!(config, :kubernetes_selector)
    cond do
      app_name != nil and selector != nil ->
        selector = URI.encode(selector)
        endpoints_path = "api/v1/namespaces/#{namespace}/endpoints?labelSelector=#{selector}"
        headers        = [{'authorization', 'Bearer #{token}'}]
        http_options   = [ssl: [verify: :verify_none]]
        case :httpc.request(:get, {'https://#{@kubernetes_master}/#{endpoints_path}', headers}, http_options, []) do
          {:ok, {{_version, 200, _status}, _headers, body}} ->
            parse_response(Keyword.get(config, :mode, :ip), app_name, Poison.decode!(body))
          {:ok, {{_version, 403, _status}, _headers, body}} ->
            %{"message" => msg} = Poison.decode!(body)
            warn topology, "cannot query kubernetes (unauthorized): #{msg}"
            []
          {:ok, {{_version, code, status}, _headers, body}} ->
            warn topology, "cannot query kubernetes (#{code} #{status}): #{inspect body}"
            []
          {:error, reason} ->
            error topology, "request to kubernetes failed!: #{inspect reason}"
            []
        end
      app_name == nil ->
        warn topology, "kubernetes strategy is selected, but :kubernetes_node_basename is not configured!"
        []
      selector == nil ->
        warn topology, "kubernetes strategy is selected, but :kubernetes_selector is not configured!"
        []
      :else ->
        warn topology, "kubernetes strategy is selected, but is not configured!"
        []
    end
  end

  defp parse_response(:ip, app_name, resp) do
    case resp do
      %{"items" => []} ->
        []
      %{"items" => items} ->
        Enum.reduce(items, [], fn
          %{"subsets" => []}, acc ->
            acc
          %{"subsets" => subsets}, acc ->
            addrs = Enum.flat_map(subsets, fn
              %{"addresses" => addresses} ->
                Enum.map(addresses, fn %{"ip" => ip} -> :"#{app_name}@#{ip}" end)
              _ ->
                []
            end)
            acc ++ addrs
          _, acc ->
            acc
        end)
      _ ->
        []
    end
  end

  defp parse_response(:dns, app_name, resp) do
    case resp do
      %{"items" => []} ->
        []
      %{"items" => items} ->
        Enum.reduce(items, [], fn
          %{"subsets" => []}, acc ->
            acc
          %{"subsets" => subsets}, acc ->
            addrs = Enum.flat_map(subsets, fn
          %{"addresses" => addresses} ->
            Enum.map(addresses, fn %{"ip" => ip, "targetRef" => %{"namespace" => namespace}} -> format_dns_record(app_name, ip, namespace) end)
          _ ->
            []
        end)
          acc ++ addrs
          _, acc ->
            acc
        end)
      _ ->
        []
    end
  end

  defp format_dns_record(app_name, ip, namespace) do
    ip = String.replace(ip, ".", "-")
    :"#{app_name}@#{ip}.#{namespace}.pod.cluster.local"
  end
end
