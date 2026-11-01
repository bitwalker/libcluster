defmodule Cluster.Strategy.KubernetesPeerTrustTest do
  use Cluster.HTTPSFixture, async: false

  import ExUnit.CaptureLog
  import Bitwise, only: [bxor: 2]

  alias Cluster.Strategy.{Kubernetes, State}

  @response ~s({"items":[{"subsets":[{"addresses":[{"ip":"10.0.0.2"}]}]}]})
  @previous MapSet.new([:"existing@10.0.0.1"])
  @discovered MapSet.new([:"test@10.0.0.2"])

  setup_all do
    trusted = Cluster.HTTPSFixture.self_signed_certificate(~c"localhost")
    {:RSAPrivateKey, der} = trusted[:key]
    key = :public_key.der_decode(:RSAPrivateKey, der)

    certificate = fn options ->
      Cluster.HTTPSFixture.self_signed_certificate(~c"localhost", [key: key] ++ options)
    end

    cert = trusted[:cert]
    prefix = binary_part(cert, 0, byte_size(cert) - 1)
    last = :binary.last(cert)

    %{
      trusted: trusted,
      unrelated: Cluster.HTTPSFixture.self_signed_certificate(~c"localhost"),
      renewed: certificate.(validity: {{2025, 1, 1}, {2040, 1, 1}}),
      wrong_host: Cluster.HTTPSFixture.self_signed_certificate(~c"other.invalid", key: key),
      expired: certificate.(validity: {{2000, 1, 1}, {2001, 1, 1}}),
      future: certificate.(validity: {{2040, 1, 1}, {2041, 1, 1}}),
      client_only: certificate.(extensions: [eku(false, [{1, 3, 6, 1, 5, 5, 7, 3, 2}])]),
      critical_client_only: certificate.(extensions: [eku(true, [{1, 3, 6, 1, 5, 5, 7, 3, 2}])]),
      critical_server: certificate.(extensions: [eku(true, [{1, 3, 6, 1, 5, 5, 7, 3, 1}])]),
      unknown_critical: certificate.(extensions: [{:Extension, {1, 2, 3, 4, 5}, true, <<5, 0>>}]),
      wrong_usage: certificate.(extensions: [{:Extension, {2, 5, 29, 15}, true, [:cRLSign]}]),
      ip: certificate.(extensions: [san([{:iPAddress, [127, 0, 0, 1]}])]),
      wrong_ip: certificate.(extensions: [san([{:iPAddress, [127, 0, 0, 2]}])]),
      bad_signature: Keyword.put(trusted, :cert, prefix <> <<bxor(last, 1)>>)
    }
  end

  for ca <- [:missing, :malformed] do
    test "accepts the configured server with #{ca} CA material in peer mode", context do
      path = pin(context, [context.trusted])
      ca = Path.join(context.directory, "ca.crt")
      File.rm!(ca)
      if unquote(ca) == :malformed, do: File.write!(ca, "not a CA")
      port = start_https(context.trusted, @response)

      assert discover(context, port, path).meta == @discovered
      assert_receive {:tls_request, request}
      assert request =~ ~r/authorization: Bearer dummy-token/i
      assert_receive {:connect, :"test@10.0.0.2"}
    end
  end

  test "retains default CA verification when the peer setting is nil", context do
    port = start_https(context.valid, @response)
    assert discover(context, port, nil).meta == @discovered
    assert_receive {:tls_request, _}
  end

  test "does not treat a self-signed certificate in ca.crt as an implicit pin", context do
    File.write!(Path.join(context.directory, "ca.crt"), pem([context.trusted]))
    port = start_https(context.trusted, @response)
    assert discover(context, port, nil).meta == @previous
    refute_receive {:tls_request, _}
  end

  for certificate <- [:unrelated, :renewed] do
    test "rejects an unlisted #{certificate} certificate", context do
      path = pin(context, [context.trusted])
      port = start_https(context[unquote(certificate)], @response)
      assert_rejected(context, port, path)
    end
  end

  test "does not fall back to the CA in explicit peer mode", context do
    path = pin(context, [context.trusted])
    port = start_https(context.valid, @response)
    assert_rejected(context, port, path)
  end

  for certificate <- [
        :wrong_host,
        :expired,
        :future,
        :client_only,
        :critical_client_only,
        :unknown_critical,
        :wrong_usage,
        :bad_signature
      ] do
    test "rejects a pinned #{certificate} certificate", context do
      certificate = context[unquote(certificate)]
      path = pin(context, [certificate])
      port = start_https(certificate, @response)
      assert_rejected(context, port, path)
    end
  end

  test "accepts a critical serverAuth extended usage", context do
    path = pin(context, [context.critical_server])
    port = start_https(context.critical_server, @response)
    assert discover(context, port, path).meta == @discovered
    assert_receive {:tls_request, _}
  end

  test "matches a literal IP against its IP subject alternative name", context do
    path = pin(context, [context.ip])
    port = start_https(context.ip, @response)
    assert discover(context, port, path, hostname: "127.0.0.1").meta == @discovered
    assert_receive {:tls_request, _}
  end

  for certificate <- [:trusted, :wrong_ip] do
    test "rejects #{certificate} when its SAN does not match the literal IP", context do
      certificate = context[unquote(certificate)]
      path = pin(context, [certificate])
      port = start_https(certificate, @response)
      assert_rejected(context, port, path, hostname: "127.0.0.1")
    end
  end

  test "accepts a final DNS dot without treating the port as part of the hostname", context do
    path = pin(context, [context.trusted])
    port = start_https(context.trusted, @response)
    assert discover(context, port, path, hostname: "localhost.").meta == @discovered
    assert_receive {:tls_request, _}
  end

  for material <- [:missing, :empty, :malformed, :directory, :invalid_der, :mixed, :private_key] do
    test "fails closed for #{material} peer material even with a trusted CA", context do
      path = Path.join(context.directory, "peers.pem")

      case unquote(material) do
        :missing ->
          :ok

        :empty ->
          File.write!(path, "")

        :malformed ->
          File.write!(path, "not a certificate")

        :directory ->
          File.mkdir!(path)

        :invalid_der ->
          File.write!(path, :public_key.pem_encode([{:Certificate, <<1, 2>>, :not_encrypted}]))

        :mixed ->
          File.write!(
            path,
            pem([context.trusted]) <>
              :public_key.pem_encode([{:Certificate, <<1, 2>>, :not_encrypted}])
          )

        :private_key ->
          {type, der} = context.trusted[:key]

          File.write!(
            path,
            pem([context.trusted]) <> :public_key.pem_encode([{type, der, :not_encrypted}])
          )
      end

      port = start_https(context.valid, @response)
      assert_rejected(context, port, path)
    end
  end

  test "rejects an invalid peer setting without crashing or using the CA", context do
    port = start_https(context.valid, @response)
    assert_rejected(context, port, 123)
  end

  for version <- [:"tlsv1.2", :"tlsv1.3"] do
    test "reloads pins without pooled connections or resumption on #{version}", context do
      path = pin(context, [context.trusted])
      certificate = Keyword.put(context.trusted, :versions, [unquote(version)])
      port = start_https(certificate, @response, 200, keep_alive: true)
      loaded = discover(context, port, path)
      assert loaded.meta == @discovered
      assert_receive {:tls_request, _}
      assert_receive {:connect, _}
      assert_receive {:disconnect, _}

      File.write!(path, pem([context.expired, context.trusted, context.renewed]))
      loaded = reload(loaded)
      assert loaded.meta == @discovered
      assert_receive {:tls_request, _}

      File.write!(path, pem([context.renewed]))
      assert reload(loaded).meta == @discovered
      refute_receive {:tls_request, _}
      refute_receive {:disconnect, _}

      File.write!(path, pem([context.trusted]))
      assert reload(loaded).meta == @discovered
      assert_receive {:tls_request, _}

      File.rm!(path)
      assert reload(loaded).meta == @discovered
      refute_receive {:tls_request, _}
    end
  end

  test "accepts a renewed certificate during overlap", context do
    path = pin(context, [context.trusted, context.renewed])
    port = start_https(context.renewed, @response)
    assert discover(context, port, path).meta == @discovered
    assert_receive {:tls_request, _}
  end

  test "never reuses a connection established with CA trust", context do
    port = start_https(context.valid, @response, 200, keep_alive: true)
    assert discover(context, port, nil).meta == @discovered
    assert_receive {:tls_request, _}
    assert_receive {:connect, _}
    assert_receive {:disconnect, _}

    path = pin(context, [context.trusted])
    assert_rejected(context, port, path)
  end

  test "does not follow a redirect with the bearer token", context do
    path = pin(context, [context.trusted])
    destination = start_https(context.trusted, @response)
    response = fn -> {302, "", [{"location", "https://localhost:#{destination}/redirected"}]} end
    source = start_https(context.trusted, response)

    assert discover(context, source, path).meta == @previous
    assert_receive {:tls_request, request}
    assert request =~ "/api/v1/namespaces/default/endpoints?"
    refute_receive {:tls_request, _}
    refute_receive {:disconnect, _}
  end

  test "rechecks pins on every EndpointSlice page", context do
    counter = start_supervised!({Agent, fn -> 0 end})

    body = fn ->
      page = Agent.get_and_update(counter, &{&1, &1 + 1})

      Jason.encode!(%{
        "metadata" => %{"continue" => if(page == 0, do: "second-page", else: "")},
        "items" => [%{"addressType" => "IPv4", "endpoints" => [%{"addresses" => ["10.0.0.2"]}]}]
      })
    end

    path = pin(context, [context.trusted])
    port = start_https(context.trusted, body, 200, keep_alive: true)

    assert discover(context, port, path, kubernetes_ip_lookup_mode: :endpoint_slices).meta ==
             @discovered

    assert_receive {:tls_request, first}
    assert_receive {:tls_request, second}
    assert first =~ "connection: close"
    assert second =~ "connection: close"
    assert second =~ "continue=second-page"
  end

  defp discover(context, port, path, options \\ []) do
    hostname = Keyword.get(options, :hostname, "localhost")

    state = %State{
      topology: :peer_trust_test,
      meta: @previous,
      config:
        Keyword.merge(
          [
            kubernetes_master: "#{hostname}:#{port}",
            kubernetes_node_basename: "test",
            kubernetes_namespace: "default",
            kubernetes_selector: "app=test",
            kubernetes_service_account_path: context.directory,
            kubernetes_trusted_peer_cert_file: path,
            polling_interval: 60_000
          ],
          Keyword.delete(options, :hostname)
        ),
      connect: {Cluster.Nodes, :connect, [self()]},
      disconnect: {Cluster.Nodes, :disconnect, [self()]},
      list_nodes: {Cluster.Nodes, :list_nodes, [MapSet.to_list(@previous)]}
    }

    capture_log(fn ->
      assert {:ok, loaded} = Kubernetes.init([state])
      send(self(), {:loaded_state, loaded})
    end)

    assert_receive {:loaded_state, loaded}
    loaded
  end

  defp reload(state) do
    capture_log(fn ->
      assert {:noreply, loaded} = Kubernetes.handle_info(:load, state)
      send(self(), {:loaded_state, loaded})
    end)

    assert_receive {:loaded_state, loaded}
    loaded
  end

  defp assert_rejected(context, port, path, options \\ []) do
    assert discover(context, port, path, options).meta == @previous
    refute_receive {:tls_request, _}
    refute_receive {:disconnect, _}
  end

  defp pin(context, certificates) do
    path = Path.join(context.directory, "peers.pem")
    File.write!(path, pem(certificates))
    path
  end

  defp pem(certificates) do
    :public_key.pem_encode(Enum.map(certificates, &{:Certificate, &1[:cert], :not_encrypted}))
  end

  defp eku(critical, purposes), do: {:Extension, {2, 5, 29, 37}, critical, purposes}
  defp san(names), do: {:Extension, {2, 5, 29, 17}, false, names}
end
