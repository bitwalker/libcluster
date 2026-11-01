defmodule Cluster.HTTPSFixture do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Cluster.HTTPSFixture, only: [start_https: 2, start_https: 3, start_https: 4]
    end
  end

  setup_all do
    Code.ensure_loaded!(Cluster.Nodes)

    root =
      :public_key.pkix_test_root_cert(~c"libcluster test CA",
        key: {:rsa, 2048, 65537},
        digest: :sha256
      )

    %{root: root, ca: root.cert, valid: certificate(root, ~c"localhost")}
  end

  setup context do
    directory =
      Path.join(
        System.tmp_dir!(),
        "libcluster-https-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "token"), "dummy-token")

    File.write!(
      Path.join(directory, "ca.crt"),
      :public_key.pem_encode([{:Certificate, context.ca, :not_encrypted}])
    )

    # Synchronous cases can use an ephemeral loopback port in kubernetes_master.
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

  def certificate(root, hostname, options \\ []) do
    peer = [
      key: {:rsa, 2048, 65537},
      digest: :sha256,
      extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, hostname}]}]
    ]

    :public_key.pkix_test_data(%{root: root, peer: peer ++ options})
  end

  def self_signed_certificate(hostname, options \\ []) do
    extensions = [
      {:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, false, :asn1_NOVALUE}},
      {:Extension, {2, 5, 29, 15}, true, [:digitalSignature, :keyEncipherment]},
      {:Extension, {2, 5, 29, 37}, false, [{1, 3, 6, 1, 5, 5, 7, 3, 1}]},
      {:Extension, {2, 5, 29, 17}, false, [{:dNSName, hostname}]}
    ]

    overrides = Keyword.get(options, :extensions, [])
    overridden = Enum.map(overrides, &elem(&1, 1))
    extensions = overrides ++ Enum.reject(extensions, &(elem(&1, 1) in overridden))

    %{cert: cert, key: key} =
      :public_key.pkix_test_root_cert(
        ~c"libcluster self-signed server",
        Keyword.merge([key: {:rsa, 2048, 65537}, digest: :sha256], options)
        |> Keyword.put(:extensions, extensions)
      )

    [cert: cert, key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)}]
  end

  def start_https(certificates, body, status \\ 200, options \\ []) do
    keep_alive = Keyword.get(options, :keep_alive, false)

    options =
      Keyword.take(certificates, [:cert, :key, :versions]) ++
        [ip: {127, 0, 0, 1}, active: false, reuseaddr: true]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    Task.Supervisor.start_child(supervisor, fn ->
      serve(listener, supervisor, owner, body, status, keep_alive)
    end)

    on_exit(fn -> :ssl.close(listener) end)
    port
  end

  defp serve(listener, supervisor, owner, body, status, keep_alive) do
    case :ssl.transport_accept(listener, 1_000) do
      {:ok, socket} ->
        Task.Supervisor.start_child(supervisor, fn ->
          serve(listener, supervisor, owner, body, status, keep_alive)
        end)

        with {:ok, socket} <- :ssl.handshake(socket, 5_000) do
          respond(socket, owner, body, status, keep_alive)
        end

        :ssl.close(socket)

      {:error, :timeout} ->
        serve(listener, supervisor, owner, body, status, keep_alive)

      {:error, :closed} ->
        :ok
    end
  end

  defp respond(socket, owner, body, status, keep_alive) do
    with {:ok, request} <- receive_headers(socket, "") do
      send(owner, {:tls_request, request})
      response = if is_function(body, 0), do: body.(), else: body

      {response_status, response_body, response_headers} =
        case response do
          {code, payload, headers} -> {code, payload, headers}
          {code, payload} -> {code, payload, []}
          payload -> {status, payload, []}
        end

      connection = if keep_alive, do: "keep-alive", else: "close"

      :ssl.send(socket, [
        "HTTP/1.1 #{response_status} Fixture\r\nContent-Length: #{byte_size(response_body)}\r\nConnection: #{connection}\r\n",
        Enum.map(response_headers, fn {key, value} -> "#{key}: #{value}\r\n" end),
        "\r\n",
        response_body
      ])

      if keep_alive, do: respond(socket, owner, body, status, keep_alive)
    end
  end

  defp receive_headers(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      {:ok, received}
    else
      with {:ok, data} <- :ssl.recv(socket, 0, 5_000) do
        receive_headers(socket, received <> IO.iodata_to_binary(data))
      end
    end
  end
end
