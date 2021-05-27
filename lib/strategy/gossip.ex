defmodule Cluster.Strategy.Gossip do
  @moduledoc """
  This clustering strategy uses multicast UDP to gossip node names
  to other nodes on the network. These packets are listened for on
  each node as well, and a connection will be established between the
  two nodes if they are reachable on the network, and share the same
  magic cookie. In this way, a cluster of nodes may be formed dynamically.

  The gossip protocol is extremely simple, with a prelude followed by the node
  name which sent the packet. The node name is parsed from the packet, and a
  connection attempt is made. It will fail if the two nodes do not share a cookie.

  By default, the gossip occurs on port 45892, using the multicast address 233.252.1.32

  The gossip protocol is not encrypted by default, but can be by providing a secret
  in the configuration of the strategy (as shown below).
  This can also be used to run multiple clusters with the same multicast configuration,
  as nodes not sharing the same encryption key will not be connected.

  You may configure the multicast interface, multicast address, the interface address to bind to, the port,
  the TTL of the packets and the optional secret using the following settings:

      config :libcluster,
        topologies: [
          gossip_example: [
            strategy: #{__MODULE__},
            config: [
              port: 45892,
              if_addr: "0.0.0.0",
              multicast_if: "192.168.1.1",
              multicast_addr: "233.252.1.32",
              multicast_ttl: 1,
              secret: "somepassword"]]]

  A TTL of 1 will limit packets to the local network, and is the default TTL.

  Optionally, `broadcast_only: true` option can be set which disables multicast and
  only uses broadcasting. This limits connectivity to local network but works on in
  scenarios where multicast is not enabled. Use `multicast_addr` as the broadcast address.

  Example for broadcast only:

      config :libcluster,
        topologies: [
          gossip_example: [
            strategy: #{__MODULE__},
            config: [
              port: 45892,
              if_addr: "0.0.0.0",
              multicast_addr: "255.255.255.255",
              broadcast_only: true]]]

  Debug logging is deactivated by default for this clustering strategy, but it can be easily activated by configuring the application:

      use Mix.Config

      config :libcluster,
        debug: true

  All the checks are done at runtime, so you can flip the debug level without being forced to shutdown your node.
  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_port 45892
  @default_addr {0, 0, 0, 0}
  @default_multicast_addr {233, 252, 1, 32}
  @sol_socket 0xFFFF
  @so_reuseport 0x0200

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init([%State{config: config} = state]) do
    port = Keyword.get(config, :port, @default_port)

    ip =
      config
      |> Keyword.get(:if_addr, @default_addr)
      |> sanitize_ip()

    broadcast_only? = Keyword.get(config, :broadcast_only, false)
    ttl = Keyword.get(config, :multicast_ttl, 1)

    multicast_if = Keyword.get(config, :multicast_if)

    multicast_addr =
      config
      |> Keyword.get(:multicast_addr, @default_multicast_addr)
      |> sanitize_ip()

    multicast_opts =
      cond do
        broadcast_only? ->
          []

        multicast_if != nil ->
          [
            multicast_if: sanitize_ip(multicast_if),
            multicast_ttl: ttl,
            multicast_loop: true
          ]

        :else ->
          [
            multicast_ttl: ttl,
            multicast_loop: true
          ]
      end

    options =
      [
        :binary,
        active: true,
        ip: ip,
        reuseaddr: true,
        broadcast: true,
        add_membership: {multicast_addr, {0, 0, 0, 0}}
      ] ++ multicast_opts ++ reuse_port()

    {:ok, socket} = :gen_udp.open(port, options)

    secret = Keyword.get(config, :secret, nil)
    state = %State{state | :meta => {multicast_addr, port, socket, secret}}

    # TODO: Remove this version check when we deprecate OTP < 21 support
    if :erlang.system_info(:otp_release) >= '21' do
      {:ok, state, {:continue, nil}}
    else
      {:ok, state, 0}
    end
  end

  defp reuse_port() do
    case :os.type() do
      {:unix, os_name} ->
        cond do
          os_name in [:darwin, :freebsd, :openbsd, :netbsd] ->
            [{:raw, @sol_socket, @so_reuseport, <<1::native-32>>}]

          true ->
            []
        end

      _ ->
        []
    end
  end

  defp sanitize_ip(input) do
    case input do
      {_a, _b, _c, _d} = ip ->
        ip

      ip when is_binary(ip) ->
        {:ok, addr} = :inet.parse_ipv4_address(~c"#{ip}")
        addr
    end
  end

  # Send stuttered heartbeats
  # TODO: Remove this version check when we deprecate OTP < 21 support
  if :erlang.system_info(:otp_release) >= '21' do
    @impl true
    def handle_continue(_, state), do: handle_info(:heartbeat, state)
  else
    @impl true
    def handle_info(:timeout, state), do: handle_info(:heartbeat, state)
  end

  @impl true
  def handle_info(:heartbeat, %State{meta: {multicast_addr, port, socket, _}} = state) do
    debug(state.topology, "heartbeat")
    :gen_udp.send(socket, multicast_addr, port, heartbeat(node(), state))
    Process.send_after(self(), :heartbeat, :rand.uniform(5_000))
    {:noreply, state}
  end

  # Handle received heartbeats
  def handle_info(
        {:udp, _socket, _ip, _port, <<"heartbeat::", _::binary>> = packet},
        %State{meta: {_, _, _, secret}} = state
      )
      when is_nil(secret) do
    handle_heartbeat(state, packet)
    {:noreply, state}
  end

  def handle_info(
        {:udp, _socket, _ip, _port, <<iv::binary-size(16)>> <> ciphertext},
        %State{meta: {_, _, _, secret}} = state
      )
      when is_binary(secret) do
    case decrypt(state, ciphertext, secret, iv) do
      {:ok, plaintext} ->
        handle_heartbeat(state, plaintext)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:udp, _socket, _ip, _port, _}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{meta: {_, _, socket, _}}) do
    :gen_udp.close(socket)
    :ok
  end

  # Construct iodata representing packet to send
  defp heartbeat(node_name, %State{meta: {_, _, _, secret}})
       when is_nil(secret) do
    ["heartbeat::", :erlang.term_to_binary(%{node: node_name})]
  end

  defp heartbeat(node_name, %State{meta: {_, _, _, secret}} = state) when is_binary(secret) do
    message = "heartbeat::" <> :erlang.term_to_binary(%{node: node_name})
    {:ok, iv, msg} = encrypt(state, message, secret)

    [iv, msg]
  end

  # Upon receipt of a heartbeat, we check to see if the node
  # is connected to us, and if not, we connect to it.
  # If the connection fails, it's likely because the cookie
  # is different, and thus a node we can ignore
  @spec handle_heartbeat(State.t(), binary) :: :ok
  defp handle_heartbeat(%State{} = state, <<"heartbeat::", rest::binary>>) do
    self = node()
    connect = state.connect
    list_nodes = state.list_nodes
    topology = state.topology

    case :erlang.binary_to_term(rest) do
      %{node: ^self} ->
        :ok

      %{node: n} when is_atom(n) ->
        debug(state.topology, "received heartbeat from #{n}")
        Cluster.Strategy.connect_nodes(topology, connect, list_nodes, [n])
        :ok

      _ ->
        :ok
    end
  end

  defp handle_heartbeat(_state, _packet) do
    :ok
  end

  defp encrypt(_state, plaintext, password) do
    iv = :crypto.strong_rand_bytes(16)
    key = :crypto.hash(:sha256, password)
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, pkcs7_pad(plaintext), true)

    {:ok, iv, ciphertext}
  end

  defp decrypt(state, ciphertext, password, iv) do
    key = :crypto.hash(:sha256, password)

    with {:unpadding, {:ok, padded}} <- {:unpadding, safe_decrypt(state, key, iv, ciphertext)},
         {:decrypt, {:ok, _plaintext} = res} <- {:decrypt, pkcs7_unpad(padded)} do
      res
    else
      {:unpadding, :error} -> {:error, :decrypt}
      {:decrypt, :error} -> {:error, :unpadding}
    end
  end

  defp safe_decrypt(state, key, iv, ciphertext) do
    try do
      {:ok, :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)}
    catch
      :error, {tag, {file, line}, desc} ->
        warn(state.topology, "decryption failed: #{inspect(tag)} (#{file}:#{line}): #{desc}")
        :error
    end
  end

  #
  # Pads a message using the PKCS #7 cryptographic message syntax.
  #
  # from: https://github.com/izelnakri/aes256/blob/master/lib/aes256.ex
  #
  # See: https://tools.ietf.org/html/rfc2315
  # See: `pkcs7_unpad/1`
  defp pkcs7_pad(message) do
    bytes_remaining = rem(byte_size(message), 16)
    padding_size = 16 - bytes_remaining
    message <> :binary.copy(<<padding_size>>, padding_size)
  end

  #
  # Unpads a message using the PKCS #7 cryptographic message syntax.
  #
  # from: https://github.com/izelnakri/aes256/blob/master/lib/aes256.ex
  #
  # See: https://tools.ietf.org/html/rfc2315
  # See: `pkcs7_pad/1`
  defp pkcs7_unpad(<<>>), do: :error

  defp pkcs7_unpad(message) do
    padding_size = :binary.last(message)

    if padding_size <= 16 do
      message_size = byte_size(message)

      if binary_part(message, message_size, -padding_size) ===
           :binary.copy(<<padding_size>>, padding_size) do
        {:ok, binary_part(message, 0, message_size - padding_size)}
      else
        :error
      end
    else
      :error
    end
  end
end
