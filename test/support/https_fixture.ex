defmodule Cluster.HTTPSFixture do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Cluster.HTTPSFixture, only: [start_https: 2, start_https: 3]
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
      Path.join(System.tmp_dir!(), "libcluster-https-#{System.unique_integer([:positive])}")

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

  def start_https(certificates, body, status \\ 200) do
    options =
      Keyword.take(certificates, [:cert, :key]) ++
        [ip: {127, 0, 0, 1}, active: false, reuseaddr: true]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()
    start_supervised!({Task, fn -> serve(listener, owner, body, status) end}, id: make_ref())
    on_exit(fn -> :ssl.close(listener) end)
    port
  end

  defp serve(listener, owner, body, status) do
    case :ssl.transport_accept(listener, 1_000) do
      {:ok, socket} ->
        with {:ok, socket} <- :ssl.handshake(socket, 5_000),
             {:ok, request} <- receive_headers(socket, "") do
          send(owner, {:tls_request, request})
          response = if is_function(body, 0), do: body.(), else: body

          {response_status, response_body} =
            case response do
              {code, payload} -> {code, payload}
              payload -> {status, payload}
            end

          :ssl.send(socket, [
            "HTTP/1.1 #{response_status} Fixture\r\nContent-Length: #{byte_size(response_body)}\r\nConnection: close\r\n\r\n",
            response_body
          ])
        end

        :ssl.close(socket)
        serve(listener, owner, body, status)

      {:error, :timeout} ->
        serve(listener, owner, body, status)

      {:error, :closed} ->
        :ok
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
