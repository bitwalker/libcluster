defmodule Cluster.Strategy.KubernetesTLSTest do
  use Cluster.HTTPSFixture, async: false

  import ExUnit.CaptureLog

  alias Cluster.Strategy.Kubernetes
  alias Cluster.Strategy.State

  @response ~s({"items":[{"subsets":[{"addresses":[{"ip":"10.0.0.2","targetRef":{"namespace":"default"}}]}]}]})

  setup_all context do
    %{
      wrong_host: Cluster.HTTPSFixture.certificate(context.root, ~c"other.invalid"),
      expired:
        Cluster.HTTPSFixture.certificate(context.root, ~c"localhost",
          validity: {{2000, 1, 1}, {2001, 1, 1}}
        )
    }
  end

  test "connects through a trusted HTTPS server", context do
    port = start_https(context.valid, @response)
    state = discover(port, context.directory)

    assert state.meta == MapSet.new([:"test@10.0.0.2"])
    assert_receive {:tls_request, request}
    assert request =~ ~r/authorization: Bearer dummy-token/i
    assert_receive {:connect, :"test@10.0.0.2"}
  end

  test "accepts a fully qualified master with a final DNS dot", context do
    port = start_https(context.valid, @response)
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

      port = start_https(context.valid, @response)
      previous = MapSet.new([:"existing@10.0.0.1"])
      state = discover(port, context.directory, "localhost", previous)

      assert state.meta == previous
      refute_receive {:tls_request, _}
      refute_receive {:disconnect, _}
    end
  end

  for certificate <- [:wrong_host, :expired] do
    test "rejects a #{certificate} server before sending credentials", context do
      port = start_https(context[unquote(certificate)], @response)
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

    port = start_https(context.valid, @response)

    assert discover(port, context.directory).meta == MapSet.new()
    refute_receive {:tls_request, _}
  end

  test "recovers on a later poll when missing trust material is restored", context do
    path = Path.join(context.directory, "ca.crt")
    ca = File.read!(path)
    File.rm!(path)
    port = start_https(context.valid, @response)
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
end
