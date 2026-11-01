defmodule Cluster.Strategy.KubernetesTLSTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cluster.Strategy.Kubernetes
  alias Cluster.Strategy.State

  require Cluster.Nodes

  @response ~s({"items":[{"subsets":[{"addresses":[{"ip":"10.0.0.2","targetRef":{"namespace":"default"}}]}]}]})

  setup_all do
    root =
      :public_key.pkix_test_root_cert(~c"libcluster test CA",
        key: {:rsa, 2048, 65537},
        digest: :sha256
      )

    certificates =
      for {name, hostname, options} <- [
            {:valid, ~c"localhost", []},
            {:wrong_host, ~c"other.invalid", []},
            {:expired, ~c"localhost", [validity: {{2000, 1, 1}, {2001, 1, 1}}]}
          ],
          into: %{} do
        peer = [
          key: {:rsa, 2048, 65537},
          digest: :sha256,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, hostname}]}]
        ]

        {name, :public_key.pkix_test_data(%{root: root, peer: peer ++ options})}
      end

    Map.put(certificates, :ca, root.cert)
  end

  setup context do
    directory =
      Path.join(System.tmp_dir!(), "libcluster-tls-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "token"), "dummy-token")

    File.write!(
      Path.join(directory, "ca.crt"),
      :public_key.pem_encode([{:Certificate, context.ca, :not_encrypted}])
    )

    # Permit a loopback server's ephemeral port without changing production configuration.
    previous_domain = System.get_env("CLUSTER_DOMAIN")
    System.put_env("CLUSTER_DOMAIN", "")

    on_exit(fn ->
      if previous_domain,
        do: System.put_env("CLUSTER_DOMAIN", previous_domain),
        else: System.delete_env("CLUSTER_DOMAIN")

      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "connects through a trusted HTTPS server", context do
    port = tls_server(context.valid)
    state = discover(port, context.directory)

    assert state.meta == MapSet.new([:"test@10.0.0.2"])
    assert_receive {:tls_request, request}
    assert request =~ ~r/authorization: Bearer dummy-token/i
    assert_receive {:connect, :"test@10.0.0.2"}
  end

  test "accepts a fully qualified master with a final DNS dot", context do
    port = tls_server(context.valid)
    assert discover(port, context.directory, "localhost.").meta == MapSet.new([:"test@10.0.0.2"])
    assert_receive {:tls_request, _}
  end

  for invalid_ca <- [:missing, :empty, :malformed, :directory] do
    test "does not send credentials with #{invalid_ca} CA material", context do
      path = Path.join(context.directory, "ca.crt")
      File.rm!(path)

      case unquote(invalid_ca) do
        :missing -> :ok
        :empty -> File.write!(path, "")
        :malformed -> File.write!(path, "invalid certificate")
        :directory -> File.mkdir!(path)
      end

      port = tls_server(context.valid)
      previous = MapSet.new([:"existing@10.0.0.1"])
      state = discover(port, context.directory, "localhost", previous)

      assert state.meta == previous
      refute_receive {:tls_request, _}
      refute_receive {:disconnect, _}
    end
  end

  for certificate <- [:wrong_host, :expired] do
    test "rejects a #{certificate} server before sending credentials", context do
      port = tls_server(context[unquote(certificate)])
      assert discover(port, context.directory).meta == MapSet.new()
      refute_receive {:tls_request, _}
    end
  end

  test "rejects an untrusted issuer before sending credentials", context do
    root =
      :public_key.pkix_test_root_cert(~c"unrelated test CA",
        key: {:rsa, 2048, 65537},
        digest: :sha256
      )

    File.write!(
      Path.join(context.directory, "ca.crt"),
      :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}])
    )

    port = tls_server(context.valid)

    assert discover(port, context.directory).meta == MapSet.new()
    refute_receive {:tls_request, _}
  end

  test "recovers on a later poll when missing trust material is restored", context do
    path = Path.join(context.directory, "ca.crt")
    ca = File.read!(path)
    File.rm!(path)
    port = tls_server(context.valid)
    state = discover(port, context.directory)
    refute_receive {:tls_request, _}

    File.write!(path, ca)

    capture_log(fn ->
      assert {:noreply, recovered} = Kubernetes.handle_info(:load, state)
      assert recovered.meta == MapSet.new([:"test@10.0.0.2"])
    end)

    assert_receive {:tls_request, _}
    assert_receive {:connect, :"test@10.0.0.2"}
  end

  defp discover(port, directory, hostname \\ "localhost", meta \\ MapSet.new()) do
    state = %State{
      topology: :tls_test,
      meta: meta,
      config: [
        kubernetes_master: "#{hostname}:#{port}",
        kubernetes_node_basename: "test",
        kubernetes_namespace: "default",
        kubernetes_selector: "app=test",
        kubernetes_service_account_path: directory,
        polling_interval: 60_000
      ],
      connect: {Cluster.Nodes, :connect, [self()]},
      disconnect: {Cluster.Nodes, :disconnect, [self()]},
      list_nodes: {Cluster.Nodes, :list_nodes, [MapSet.to_list(meta)]}
    }

    capture_log(fn ->
      assert {:ok, loaded} = Kubernetes.init([state])
      send(self(), {:loaded_state, loaded})
    end)

    assert_receive {:loaded_state, loaded}
    loaded
  end

  defp tls_server(certificates) do
    options =
      Keyword.take(certificates, [:cert, :key]) ++
        [ip: {127, 0, 0, 1}, active: false, reuseaddr: true]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()
    start_supervised!({Task, fn -> serve(listener, owner) end}, id: make_ref())
    on_exit(fn -> :ssl.close(listener) end)
    port
  end

  defp serve(listener, owner) do
    case :ssl.transport_accept(listener, 1_000) do
      {:ok, socket} ->
        with {:ok, socket} <- :ssl.handshake(socket, 1_000),
             {:ok, request} <- :ssl.recv(socket, 0, 1_000) do
          send(owner, {:tls_request, IO.iodata_to_binary(request)})

          :ssl.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(@response)}\r\nConnection: close\r\n\r\n",
            @response
          ])
        end

        :ssl.close(socket)
        serve(listener, owner)

      {:error, :timeout} ->
        serve(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end
end
