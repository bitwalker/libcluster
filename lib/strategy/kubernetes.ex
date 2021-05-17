defmodule Cluster.Strategy.Kubernetes do
  @moduledoc """
  This clustering strategy works by loading all endpoints in the current Kubernetes
  namespace with the configured label. It will fetch the addresses of all endpoints with
  that label and attempt to connect. It will continually monitor and update its
  connections every 5s. Alternatively the IP can be looked up from the pods directly
  by setting `kubernetes_ip_lookup_mode` to `:pods`.

  In order for your endpoints to be found they should be returned when you run:

      kubectl get endpoints -l app=myapp

  In order for your pods to be found they should be returned when you run:

      kubectl get pods -l app=myapp

  It assumes that all nodes share a base name, are using longnames, and are unique
  based on their FQDN, rather than the base hostname. In other words, in the following
  longname, `<basename>@<domain>`, `basename` would be the value configured in
  `kubernetes_node_basename`.

  `domain` would be the value configured in `mode` and can be either of type `:ip`
  (the pod's ip, can be obtained by setting an env variable to status.podIP), `:hostname`
  or `:dns`, which is the pod's internal A Record. This A Record has the format
  `<ip-with-dashes>.<namespace>.pod.cluster.local`, e.g.
  `1-2-3-4.default.pod.cluster.local`.

  Getting `:dns` to work requires setting the `POD_A_RECORD` environment variable before
  the application starts. If you use Distillery you can set it in your `pre_configure` hook:

      # deployment.yaml
      command: ["sh", "-c"]
      args: ["POD_A_RECORD"]
      args: ["export POD_A_RECORD=$(echo $POD_IP | sed 's/\./-/g') && /app/bin/app foreground"]

      # vm.args
      -name app@<%= "${POD_A_RECORD}.${NAMESPACE}.pod.cluster.local" %>

  To set the `NAMESPACE` and `POD_IP` environment variables you can configure your pod as follows:

      # deployment.yaml
      env:
      - name: NAMESPACE
        valueFrom:
          fieldRef:
            fieldPath: metadata.namespace
      - name: POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP

  The benefit of using `:dns` over `:ip` is that you can establish a remote shell (as well as
  run observer) by using `kubectl port-forward` in combination with some entries in `/etc/hosts`.

  Using `:hostname` is useful when deploying your app to K8S as a stateful set.  In this case you can
  set your erlang name as the fully qualified domain name of the pod which would be something similar to
  `my-app-0.my-service-name.my-namespace.svc.cluster.local`.
  e.g.

      # vm.args
      -name app@<%=`(hostname -f)`%>

  In this case you must also set `kubernetes_service_name` to the name of the K8S service that is being queried.

  `mode` defaults to `:ip`.

  An example configuration is below:

      config :libcluster,
        topologies: [
          k8s_example: [
            strategy: #{__MODULE__},
            config: [
              mode: :ip,
              kubernetes_node_basename: "myapp",
              kubernetes_selector: "app=myapp",
              kubernetes_namespace: "my_namespace",
              polling_interval: 10_000]]]

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000
  @kubernetes_master "kubernetes.default.svc"
  @service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

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

  defp load(%State{topology: topology} = state) do
    new_nodelist = MapSet.new(get_nodes(state))
    removed = MapSet.difference(state.meta, new_nodelist)

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

    Process.send_after(self(), :load, polling_interval(state))

    %State{state | meta: new_nodelist}
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  @spec get_token(String.t()) :: String.t()
  defp get_token(service_account_path) do
    path = Path.join(service_account_path, "token")

    case File.exists?(path) do
      true -> path |> File.read!() |> String.trim()
      false -> ""
    end
  end

  @spec get_namespace(String.t(), String.t()) :: String.t()
  if Mix.env() == :test do
    defp get_namespace(_service_account_path, nil), do: "__libcluster_test"
  else
    defp get_namespace(service_account_path, nil) do
      path = Path.join(service_account_path, "namespace")

      if File.exists?(path) do
        path |> File.read!() |> String.trim()
      else
        ""
      end
    end
  end

  defp get_namespace(_, namespace), do: namespace

  @spec get_nodes(State.t()) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config, meta: meta}) do
    service_account_path =
      Keyword.get(config, :kubernetes_service_account_path, @service_account_path)

    token = get_token(service_account_path)

    namespace = get_namespace(service_account_path, Keyword.get(config, :kubernetes_namespace))
    app_name = Keyword.fetch!(config, :kubernetes_node_basename)
    cluster_name = Keyword.get(config, :kubernetes_cluster_name, "cluster")
    service_name = Keyword.get(config, :kubernetes_service_name)
    selector = Keyword.fetch!(config, :kubernetes_selector)
    ip_lookup_mode = Keyword.get(config, :kubernetes_ip_lookup_mode, :endpoints)

    master_name = Keyword.get(config, :kubernetes_master, @kubernetes_master)
    cluster_domain = System.get_env("CLUSTER_DOMAIN", "#{cluster_name}.local")

    master =
      cond do
        String.ends_with?(master_name, cluster_domain) ->
          master_name

        String.ends_with?(master_name, ".") ->
          # The dot at the end is used to determine that the name is "final"
          master_name

        :else ->
          master_name <> "." <> cluster_domain
      end

    cond do
      app_name != nil and selector != nil ->
        selector = URI.encode(selector)

        path =
          case ip_lookup_mode do
            :endpoints -> "api/v1/namespaces/#{namespace}/endpoints?labelSelector=#{selector}"
            :pods -> "api/v1/namespaces/#{namespace}/pods?labelSelector=#{selector}"
          end

        headers = [{'authorization', 'Bearer #{token}'}]
        http_options = [ssl: [verify: :verify_none], timeout: 15000]

        case :httpc.request(:get, {'https://#{master}/#{path}', headers}, http_options, []) do
          {:ok, {{_version, 200, _status}, _headers, body}} ->
            parse_response(ip_lookup_mode, Jason.decode!(body))
            |> Enum.map(fn node_info ->
              format_node(
                Keyword.get(config, :mode, :ip),
                node_info,
                app_name,
                cluster_name,
                service_name
              )
            end)

          {:ok, {{_version, 403, _status}, _headers, body}} ->
            %{"message" => msg} = Jason.decode!(body)
            warn(topology, "cannot query kubernetes (unauthorized): #{msg}")
            []

          {:ok, {{_version, code, status}, _headers, body}} ->
            warn(topology, "cannot query kubernetes (#{code} #{status}): #{inspect(body)}")
            meta

          {:error, reason} ->
            error(topology, "request to kubernetes failed!: #{inspect(reason)}")
            meta
        end

      app_name == nil ->
        warn(
          topology,
          "kubernetes strategy is selected, but :kubernetes_node_basename is not configured!"
        )

        []

      selector == nil ->
        warn(
          topology,
          "kubernetes strategy is selected, but :kubernetes_selector is not configured!"
        )

        []

      :else ->
        warn(topology, "kubernetes strategy is selected, but is not configured!")
        []
    end
  end

  defp parse_response(:endpoints, resp) do
    case resp do
      %{"items" => items} when is_list(items) ->
        Enum.reduce(items, [], fn
          %{"subsets" => subsets}, acc when is_list(subsets) ->
            addrs =
              Enum.flat_map(subsets, fn
                %{"addresses" => addresses} when is_list(addresses) ->
                  Enum.map(addresses, fn %{"ip" => ip, "targetRef" => %{"namespace" => namespace}} =
                                           address ->
                    %{ip: ip, namespace: namespace, hostname: address["hostname"]}
                  end)

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

  defp parse_response(:pods, resp) do
    case resp do
      %{"items" => items} when is_list(items) ->
        Enum.map(items, fn
          %{
            "status" => %{"podIP" => ip},
            "metadata" => %{"namespace" => ns},
            "spec" => pod_spec
          } ->
            %{ip: ip, namespace: ns, hostname: pod_spec["hostname"]}

          _ ->
            nil
        end)
        |> Enum.filter(&(&1 != nil))

      _ ->
        []
    end
  end

  defp format_node(:ip, %{ip: ip}, app_name, _cluster_name, _service_name),
    do: :"#{app_name}@#{ip}"

  defp format_node(
         :hostname,
         %{hostname: hostname, namespace: namespace},
         app_name,
         cluster_name,
         service_name
       ) do
    :"#{app_name}@#{hostname}.#{service_name}.#{namespace}.svc.#{cluster_name}.local"
  end

  defp format_node(:dns, %{ip: ip, namespace: namespace}, app_name, cluster_name, _service_name) do
    ip = String.replace(ip, ".", "-")
    :"#{app_name}@#{ip}.#{namespace}.pod.#{cluster_name}.local"
  end
end
