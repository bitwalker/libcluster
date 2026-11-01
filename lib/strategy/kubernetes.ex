defmodule Cluster.Strategy.Kubernetes do
  @default_polling_interval 5_000
  @kubernetes_master "kubernetes.default.svc"
  @service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

  @moduledoc """
  This clustering strategy works by fetching endpoints, pods, or EndpointSlices, filtered by
  given Kubernetes namespace and label.

  > This strategy requires a service account with the ability to list endpoints or pods. If you want
  > to avoid that, you could use one of the DNS-based strategies instead.
  >
  > See `Cluster.Strategy.Kubernetes.DNS` and `Cluster.Strategy.Kubernetes.DNSSRV`.
  > EndpointSlice lookup needs `list` permission for `discovery.k8s.io/endpointslices` instead.

  It assumes that all Erlang nodes are using longnames - `<basename>@<ip_or_domain>`:

  + all nodes are using the same `<basename>`
  + all nodes are using unique `<ip_or_domain>`

  In `<basename>@<ip_or_domain>`:

  + `<basename>` would be the value configured by `:kubernetes_node_basename` option.
  + `<ip_or_domain>` would be the value which is controlled by following options:
     - `:kubernetes_namespace`
     - `:kubernetes_selector`
     - `:kubernetes_service_name`
     - `:kubernetes_ip_lookup_mode`
     - `:kubernetes_use_cached_resources`
     - `:mode`

  ## Getting `<basename>`

  As said above, the basename is configured by `:kubernetes_node_basename` option.

  Just one thing to keep in mind - when building an OTP release, make sure that the name of the OTP
  release matches the name configured by `:kubernetes_node_basename`.

  ## Getting `<ip_or_domain>`

  ### `:kubernetes_namespace` and `:kubernetes_selector` option

  These options select a namespace and a label selector on the resource being queried.
  Labels on Pods or legacy Endpoints are not automatically usable as EndpointSlice selectors.

  ### `:kubernetes_ip_lookup_mode` option

  These option configures where to lookup the required IP.

  Available values:

  + `:endpoints` (default)
  + `:pods`
  + `:endpoint_slices`

  #### :endpoints

  When setting this value, this strategy will lookup IP from endpoints.

  In order for your endpoints to be found they should be returned when you run:

      kubectl get endpoints -l app=myapp

  Then, this strategy will fetch the addresses of all endpoints with that label and attempt to
  connect.

  #### :pods

  When setting this value, this strategy will lookup IP from pods directly.

  In order for your pods to be found they should be returned when you run:

      kubectl get pods -l app=myapp

  This strategy attempts to connect pods with that label and a nonempty pod IP, excluding pods
  with a non-null `metadata.deletionTimestamp` or a terminal phase (`Succeeded` or `Failed`).
  Other pods remain discoverable even when they are not Ready, so applications can make
  readiness depend on cluster formation without blocking discovery.

  #### :endpoint_slices

  This opt-in mode uses `discovery.k8s.io/v1`, available since Kubernetes 1.21. It lists all
  matching EndpointSlices and combines their IPv4 and IPv6 addresses, removing duplicates.
  FQDN address types are not supported. An endpoint is eligible unless `ready` is explicitly
  `false` or `terminating` is explicitly `true`; missing conditions use the API defaults.
  `serving` does not override these rules. Services that publish not-ready addresses can still
  support discovery before application readiness, but terminating endpoints are excluded.

  Select slices explicitly by their labels, typically the Service association:

      kubernetes_ip_lookup_mode: :endpoint_slices,
      kubernetes_namespace: "default",
      kubernetes_selector: "kubernetes.io/service-name=myapp",
      kubernetes_node_basename: "myapp"

  `:kubernetes_service_name` retains its hostname-formatting role; it does not add a discovery
  filter. When migrating, replace an old selector such as `app=myapp` if that label is not
  present on the slices. Verify selection with:

      kubectl get endpointslices -n default -l kubernetes.io/service-name=myapp

  Grant the service account namespace-scoped `list` permission using the
  [example Role](https://github.com/bitwalker/libcluster/blob/main/priv/endpointslice-viewer.yaml)
  and bind it with a RoleBinding. No legacy Endpoints, Pod,
  `get`, or `watch` permission is needed for this mode. The existing lookup modes and default
  remain available; a permission error never triggers a fallback to another resource.

  Lists request pages of up to 500 slices. All pages must succeed before membership changes;
  HTTP errors (including authorization or expired continuation), transport failures and invalid
  responses retain the previous membership until a fresh list on the next poll. A successful
  empty list removes previous members. This mode polls; it does not watch the API.

  ### `kubernetes_use_cached_resources` option

  This option requests `resourceVersion=0`, allowing a cached response that may be stale.
  Kubernetes resource versions are opaque identifiers, not counters. EndpointSlice continuation
  requests omit resourceVersion to follow the server's snapshot token. Older API servers may
  ignore page limits when the initial request uses resourceVersion=0.

  ### `:mode` option

  These option configures how to build the longname.

  Available values:

  + `:ip` (default)
  + `:dns`
  + `:hostname`

  #### :ip

  In this mode, the IP address is used directly. The longname will be something like:

      myapp@<ip>

  Getting this mode to work requires:

  1. exposing pod IP from Kubernetes to the Erlang node.
  2. setting the name of Erlang node according to the exposed information

  First, expose required information from Kubernetes as environment variables of Erlang node:

      # deployment.yaml
      env:
      - name: POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP

  Then, set the name of Erlang node by using the exposed environment variables. If you use mix releases, you
  can configure the required options in `rel/env.sh.eex`:

      # rel/env.sh.eex
      export RELEASE_DISTRIBUTION=name
      export RELEASE_NODE=<%= @release.name %>@${POD_IP}

  > `export RELEASE_DISTRIBUTION=name` will append a `-name` option to the `start` command directly
  > and requires no further changes to the `vm.args`.

  #### :hostname

  In this mode, the hostname is used directly. The longname will be something like:

      myapp@<hostname>.<service_name>.<namespace>.svc.<cluster_domain>

  Getting `:hostname` mode to work requires:

  1. deploying pods as a StatefulSet (otherwise, hostname is not set for pods)
  2. setting `:kubernetes_service_name` to the name of the Kubernetes service that is being lookup
  3. setting the name of Erlang node according to hostname of pods

  Then, set the name of Erlang node by using the hostname of pod. If you use mix releases, you can
  configure the required options in `rel/env.sh.eex`:

      # rel/env.sh.eex
      export RELEASE_DISTRIBUTION=name
      export RELEASE_NODE=<%= @release.name %>@$(hostname -f)

  > `hostname -f` returns the whole FQDN, which is something like:
  > `$(hostname).${SERVICE_NAME}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"`.

  #### :dns

  In this mode, an IP-based pod A record is used. The longname will be something like:

      myapp@<pod_a_record>.<namespace>.pod.<cluster_domain>

  Getting `:dns` mode to work requires:

  1. exposing pod IP from Kubernetes to the Erlang node
  2. setting the name of Erlang node according to the exposed information

  First, expose required information from Kubernetes as environment variables of Erlang node:

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

  Then, set the name of Erlang node by using the exposed environment variables. If you use mix
  releases, you can configure the required options in `rel/env.sh.eex`:

      # rel/env.sh.eex
      export POD_A_RECORD=$(echo $POD_IP | sed 's/\./-/g')
      export CLUSTER_DOMAIN=cluster.local  # modify this value according to your actual situation
      export RELEASE_DISTRIBUTION=name
      export RELEASE_NODE=<%= @release.name %>@${POD_A_RECORD}.${NAMESPACE}.pod.${CLUSTER_DOMAIN}

  IP-derived Pod DNS names require support from your cluster DNS configuration. CoreDNS needs
  `pods insecure` or `pods verified`; Pod records are disabled by default. IPv6 formatting
  replaces colons with hyphens, preserving compression (`2001:db8::1` becomes `2001-db8--1`).
  Older CoreDNS verified implementations recognize only a Pod's primary IP, so secondary
  dual-stack addresses may not resolve. Check your DNS implementation before using this mode.

  ### Which mode is the best one?

  There is no best, only the best for you:

  + If you're not using a StatefulSet, use `:ip` or `:dns`.
  + If you're using a StatefulSet, use `:hostname`.

  And, there is one thing that can be taken into consideration. When using `:ip` or `:dns`, you
  can establish a remote shell (as well as run observer) by using `kubectl port-forward` in combination
  with some entries in `/etc/hosts`.

  ## Polling Interval

  The default interval to sync topologies is `#{@default_polling_interval}`
  (#{div(@default_polling_interval, 1000)} seconds). You can configure it with `:polling_interval` option.

  ## Membership during shutdown

  Changes to discovered membership take effect on the next successful poll that observes them.
  API/controller updates and cached responses can add delay; failed disconnections are retried
  on subsequent polls.

  In `:endpoints` mode, discovery uses the API's ready `addresses` and ignores
  `notReadyAddresses`. Removal therefore depends on the controller or operator updating the
  Endpoints resource. In `:pods` mode, a deletion timestamp or terminal phase removes a pod;
  changing readiness alone does not remove it.
  EndpointSlice discovery additionally excludes explicit terminating conditions, even when a
  Service's `publishNotReadyAddresses` setting makes the endpoint appear ready.

  For graceful shutdown, stop accepting new work and withdraw application readiness, allow time
  for the discovery resource to stop advertising the peer and for another poll, then drain
  existing work before stopping the BEAM. Set the pod's termination grace period accordingly.
  Cluster membership does not migrate in-flight work, and transitive Erlang distribution
  connections can reconnect a peer independently of this strategy.

  ## Getting cluster information

  > In general, you don't need to read this, the default values will work.

  This strategy fetchs information of endpoints or pods by accessing the REST API provided by
  Kubernetes.

  The base URL of the REST API has two parts:

      <master_name>.<cluster_domain>

  `<master_name>` is configured by following options:

  + `:kubernetes_master` - the default value is `#{@kubernetes_master}`

  `<cluster_domain>` is configured by following options and environment variables:

  + `:kubernetes_cluster_name` - the default value is `cluster`, and the final cluster domain will be `<cluster_name>.local`
  + `CLUSTER_DOMAIN` - when this environment variable is provided, `:kubernetes_cluster_name` will be ignored

  > `<master_name>` and `<cluster_domain>` also affect each other, checkout the source code for more
  > details.

  Besides the base URL of the REST API, a service account must be provided. The service account is
  configured by following options:

  + `:kubernetes_service_account_path` - the default value is `#{@service_account_path}`

  The service account directory must contain a readable `ca.crt` that trusts the Kubernetes API
  server. TLS peer and hostname verification are always enabled. If the CA file is missing or
  invalid, discovery fails without sending the bearer token, retains the last known membership,
  and retries on the next poll. Restore the mounted CA file to resume discovery.

  ## An example configuration

      config :libcluster,
        topologies: [
          erlang_nodes_in_k8s: [
            strategy: #{__MODULE__},
            config: [
              mode: :ip,
              kubernetes_node_basename: "myapp",
              kubernetes_selector: "app=myapp",
              kubernetes_namespace: "my_namespace",
              polling_interval: 10_000
            ]
          ]
        ]

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State
  alias Cluster.Strategy.Kubernetes.EndpointSlice

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

  @spec get_ssl_opts(Path.t()) :: Keyword.t()
  defp get_ssl_opts(service_account_path) do
    path = Path.join(service_account_path, "ca.crt")
    [verify: :verify_peer, cacertfile: String.to_charlist(path)]
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
    ssl_opts = get_ssl_opts(service_account_path)

    namespace = get_namespace(service_account_path, Keyword.get(config, :kubernetes_namespace))
    app_name = Keyword.fetch!(config, :kubernetes_node_basename)
    cluster_name = Keyword.get(config, :kubernetes_cluster_name, "cluster")
    selector = Keyword.fetch!(config, :kubernetes_selector)
    ip_lookup_mode = Keyword.get(config, :kubernetes_ip_lookup_mode, :endpoints)

    use_cache = Keyword.get(config, :kubernetes_use_cached_resources, false)
    resource_version = if use_cache, do: 0, else: nil

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
        query_params =
          []
          |> apply_param(:labelSelector, selector)
          |> apply_param(:resourceVersion, resource_version)

        path =
          case ip_lookup_mode do
            :endpoints ->
              "api/v1/namespaces/#{namespace}/endpoints"

            :pods ->
              "api/v1/namespaces/#{namespace}/pods"

            :endpoint_slices ->
              "apis/discovery.k8s.io/v1/namespaces/#{namespace}/endpointslices"
          end

        headers = [{~c"authorization", ~c"Bearer #{token}"}]
        http_options = [ssl: ssl_opts, timeout: 15000]
        url = "https://#{master}/#{path}"

        if ip_lookup_mode == :endpoint_slices do
          case EndpointSlice.list(url, headers, http_options, query_params, namespace) do
            {:ok, nodes} ->
              format_nodes(nodes, config)

            {:error, reason} ->
              error(topology, "cannot list kubernetes EndpointSlices: #{inspect(reason)}")
              meta
          end
        else
          query = URI.encode_query(query_params, :rfc3986)

          case :httpc.request(:get, {~c"#{url}?#{query}", headers}, http_options, []) do
            {:ok, {{_version, 200, _status}, _headers, body}} ->
              parse_response(ip_lookup_mode, Jason.decode!(body), namespace)
              |> format_nodes(config)

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

  defp apply_param(params, key, value) when value != nil do
    [{key, value} | params]
  end

  defp apply_param(params, _key, _value), do: params

  defp parse_response(:endpoints, resp, namespace) do
    case resp do
      %{"items" => items} when is_list(items) ->
        Enum.reduce(items, [], fn
          %{"subsets" => subsets} = endpoint, acc when is_list(subsets) ->
            endpoint_namespace = get_in(endpoint, ["metadata", "namespace"]) || namespace

            addrs =
              Enum.flat_map(subsets, fn
                %{"addresses" => addresses} when is_list(addresses) ->
                  Enum.map(addresses, fn %{"ip" => ip} = address ->
                    namespace = get_in(address, ["targetRef", "namespace"]) || endpoint_namespace
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

  defp parse_response(:pods, resp, _namespace) do
    case resp do
      %{"items" => items} when is_list(items) ->
        Enum.flat_map(items, fn
          %{"metadata" => %{"deletionTimestamp" => timestamp}} when not is_nil(timestamp) ->
            []

          %{"status" => %{"phase" => phase}} when phase in ["Succeeded", "Failed"] ->
            []

          %{
            "status" => %{"podIP" => ip},
            "metadata" => %{"namespace" => ns},
            "spec" => pod_spec
          }
          when is_binary(ip) and ip != "" ->
            [%{ip: ip, namespace: ns, hostname: pod_spec["hostname"]}]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp format_nodes(nodes, config) do
    mode = Keyword.get(config, :mode, :ip)
    app_name = Keyword.fetch!(config, :kubernetes_node_basename)
    cluster_name = Keyword.get(config, :kubernetes_cluster_name, "cluster")
    service_name = Keyword.get(config, :kubernetes_service_name)

    nodes
    |> Enum.map(&format_node(mode, &1, app_name, cluster_name, service_name))
    |> Enum.reject(&is_nil/1)
  end

  defp format_node(:ip, %{ip: ip}, app_name, _cluster_name, _service_name),
    do: :"#{app_name}@#{ip}"

  defp format_node(
         :hostname,
         %{hostname: hostname, namespace: namespace},
         app_name,
         cluster_name,
         service_name
       )
       when is_binary(hostname) and hostname != "" and is_binary(service_name) and
              service_name != "" do
    :"#{app_name}@#{hostname}.#{service_name}.#{namespace}.svc.#{cluster_name}.local"
  end

  defp format_node(:hostname, _node_info, _app_name, _cluster_name, _service_name), do: nil

  defp format_node(:dns, %{ip: ip, namespace: namespace}, app_name, cluster_name, _service_name) do
    ip = String.replace(ip, [".", ":"], "-")
    :"#{app_name}@#{ip}.#{namespace}.pod.#{cluster_name}.local"
  end
end
