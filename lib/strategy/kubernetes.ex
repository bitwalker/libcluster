defmodule Cluster.Strategy.Kubernetes do
  @moduledoc """
  This clustering strategy works by loading all pods in the current Kubernetes
  namespace with the configured tag. It will fetch the addresses of all pods with
  that tag and attempt to connect. It will continually monitor and update it's
  connections every 5s.

  It assumes that all nodes share a base name, are using longnames, and are unique
  based on their FQDN, rather than the base hostname. In other words, in the following
  longname, `<basename>@<domain>`, `basename` would be the value configured in
  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  @kubernetes_master    "kubernetes.default.svc.cluster.local"
  @service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

  def start_link(), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_) do
    {:ok, MapSet.new([]), 0}
  end

  def handle_info(:timeout, nodelist) do
    handle_info(:load, nodelist)
  end
  def handle_info(:load, nodelist) do
    new_nodelist = MapSet.new(get_nodes())
    added        = MapSet.difference(new_nodelist, nodelist)
    removed      = MapSet.difference(nodelist, new_nodelist)
    for n <- removed do
      info "disconnected from #{inspect n}"
    end
    Cluster.Strategy.connect_nodes(MapSet.to_list(added))
    Process.send_after(self(), :load, 5_000)
    {:noreply, new_nodelist}
  end
  def handle_info(_, nodelist) do
    {:noreply, nodelist}
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

  @spec get_nodes() :: [atom()]
  defp get_nodes() do
    token     = get_token()
    namespace = get_namespace()
    app_name = Application.get_env(:libcluster, :kubernetes_node_basename)
    selector = Application.get_env(:libcluster, :kubernetes_selector)
    cond do
      app_name != nil and selector != nil ->
        selector = URI.encode(selector)
        endpoints_path = "api/v1/namespaces/#{namespace}/endpoints?labelSelector=#{selector}"
        headers        = [{'authorization', 'Bearer #{token}'}]
        http_options   = [ssl: [verify: :verify_none]]
        case :httpc.request(:get, {'https://#{@kubernetes_master}/#{endpoints_path}', headers}, http_options, []) do
          {:ok, {{_version, 200, _status}, _headers, body}} ->
            case Poison.decode!(body) do
              %{"items" => []} ->
                []
              %{"items" => items} ->
                Enum.reduce(items, [], fn
                  %{"subsets" => []}, acc ->
                    acc
                  %{"subsets" => subsets}, acc ->
                    addrs = Enum.flat_map(subsets, fn %{"addresses" => addresses} ->
                      Enum.map(addresses, fn %{"ip" => ip} -> :"#{app_name}@#{ip}" end)
                    end)
                    acc ++ addrs
                  _, acc ->
                    acc
                end)
              _ ->
                []
            end
          {:ok, {{_version, 403, _status}, _headers, body}} ->
            %{"message" => msg} = Poison.decode!(body)
            warn "cannot query kubernetes (unauthorized): #{msg}"
            []
          {:ok, {{_version, code, status}, _headers, body}} ->
            warn "cannot query kubernetes (#{code} #{status}): #{inspect body}"
            []
          {:error, reason} ->
            error "request to kubernetes failed!: #{inspect reason}"
            []
        end
      app_name == nil ->
        warn "kubernetes strategy is selected, but :kubernetes_node_basename is not configured!"
        []
      selector == nil ->
        warn "kubernetes strategy is selected, but :kubernetes_selector is not configured!"
        []
      :else ->
        warn "kubernetes strategy is selected, but is not configured!"
        []
    end
  end

end
