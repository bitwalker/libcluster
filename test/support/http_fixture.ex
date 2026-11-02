defmodule Cluster.HTTPFixture do
  @moduledoc false

  import ExUnit.Callbacks

  def start_proxy(body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    start_supervised!({Task, fn -> serve(listener, owner, body) end}, id: make_ref())
    {:ok, previous_options} = :httpc.get_options([:proxy])
    :ok = :httpc.set_options(proxy: {{~c"localhost", port}, []})

    on_exit(fn ->
      case previous_options do
        [proxy: {:undefined, []}] ->
          # The public setter cannot restore its own default undefined proxy.
          # Synchronous fixture users must reset the default profile to clear it.
          :ok = :inets.stop(:httpc, :default)
          {:ok, _} = :inets.start(:httpc, profile: :default)

        options ->
          :ok = :httpc.set_options(options)
      end

      :gen_tcp.close(listener)
    end)
  end

  defp serve(listener, owner, body) do
    case :gen_tcp.accept(listener, 1_000) do
      {:ok, socket} ->
        with {:ok, request} <- receive_headers(socket, "") do
          send(owner, {:http_request, request})
          response = body.()

          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n",
            response
          ])
        end

        :gen_tcp.close(socket)
        serve(listener, owner, body)

      {:error, :timeout} ->
        serve(listener, owner, body)

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_headers(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      {:ok, received}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000) do
        receive_headers(socket, received <> data)
      end
    end
  end
end
