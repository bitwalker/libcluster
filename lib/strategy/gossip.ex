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

  Gossip is intended for trusted networks. Encryption does not authenticate the discovery
  protocol, and anyone who can reach the gossip port can announce node names. Restrict access
  to the gossip port; configuring a secret does not make it safe to expose to untrusted senders.

  Received packets are never decoded as arbitrary Erlang terms. A heartbeat must be exactly
  the map `%{node: name}` in the external term format, where `name` is a `name@host` atom of
  at most 255 characters; anything else is ignored without creating atoms or other terms.

  Atoms are never garbage collected, so each strategy process creates at most
  `max_new_node_names` atoms (10,000 by default) for node names the VM has not seen before.
  Once that allowance is spent, a warning is logged and heartbeats naming unknown nodes are
  ignored until the strategy restarts; nodes whose names already exist as atoms, including
  every node that has connected to this one, are still discovered. Set it to `0` to accept
  only names that already exist as atoms.

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
              secret: "somepassword",
              max_new_node_names: 10_000]]]

  A TTL of 1 will limit packets to the local network, and is the default TTL.

  Multiple nodes on one host share the UDP port. Windows uses the native Winsock
  `SO_REUSEADDR` option, BSD/macOS use `SO_REUSEPORT`, and Linux uses `reuseaddr`.
  Multicast must be permitted on the chosen interface and by the host firewall. A bind failure
  stops the strategy with `{:udp_open_failed, reason, [port: port, if_addr: address]}` so an
  actual port conflict remains visible.

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
  @default_max_new_node_names 10_000
  @max_atom_characters 255
  @sol_socket 0xFFFF
  @so_reuseport 0x0200
  @windows_so_reuseaddr 0x0004

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

    max_new_node_names = max_new_node_names!(config)
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
            multicast_loop: true,
            add_membership: {multicast_addr, sanitize_ip(multicast_if)}
          ]

        :else ->
          [
            multicast_ttl: ttl,
            multicast_loop: true,
            add_membership: {multicast_addr, {0, 0, 0, 0}}
          ]
      end

    options =
      [
        :binary,
        active: true,
        ip: ip,
        reuseaddr: true,
        broadcast: true
      ] ++ multicast_opts ++ reuse_port()

    case :gen_udp.open(port, options) do
      {:ok, socket} ->
        secret = Keyword.get(config, :secret, nil)
        meta = {multicast_addr, port, socket, secret, max_new_node_names}
        state = %State{state | :meta => meta}
        {:ok, state, {:continue, nil}}

      {:error, reason} ->
        {:stop, {:udp_open_failed, reason, [port: port, if_addr: ip]}}
    end
  end

  defp max_new_node_names!(config) do
    case Keyword.get(config, :max_new_node_names, @default_max_new_node_names) do
      max when is_integer(max) and max >= 0 ->
        max

      other ->
        raise ArgumentError,
              "expected :max_new_node_names to be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp reuse_port() do
    case :os.type() do
      {:unix, os_name} when os_name in [:darwin, :freebsd, :openbsd, :netbsd] ->
        [{:raw, @sol_socket, @so_reuseport, <<1::native-32>>}]

      {:win32, _} ->
        # Set the native option explicitly: the inet driver's cached Windows
        # reuse flags can suppress setsockopt even when the OS option is unset.
        [{:raw, @sol_socket, @windows_so_reuseaddr, <<1::native-32>>}]

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
  @impl true
  def handle_continue(_, state), do: handle_info(:heartbeat, state)

  @impl true
  def handle_info(:heartbeat, %State{meta: {multicast_addr, port, socket, _, _}} = state) do
    debug(state.topology, "heartbeat")
    :gen_udp.send(socket, multicast_addr, port, heartbeat(node(), state))
    Process.send_after(self(), :heartbeat, :rand.uniform(5_000))
    {:noreply, state}
  end

  # Handle received heartbeats
  def handle_info(
        {:udp, _socket, _ip, _port, <<"heartbeat::", _::binary>> = packet},
        %State{meta: {_, _, _, secret, _}} = state
      )
      when is_nil(secret) do
    {:noreply, handle_heartbeat(state, packet)}
  end

  def handle_info(
        {:udp, _socket, _ip, _port, <<iv::binary-size(16)>> <> ciphertext},
        %State{meta: {_, _, _, secret, _}} = state
      )
      when is_binary(secret) do
    case decrypt(state, ciphertext, secret, iv) do
      {:ok, plaintext} ->
        {:noreply, handle_heartbeat(state, plaintext)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:udp, _socket, _ip, _port, _}, state) do
    {:noreply, state}
  end

  def handle_info({:udp_error, socket, reason}, %State{meta: {_, _, socket, _, _}} = state) do
    warn(state.topology, "UDP receive error: #{inspect(reason)}")
    resume_socket(socket, state)
  end

  def handle_info({:udp_closed, socket}, %State{meta: {_, _, socket, _, _}} = state) do
    resume_socket(socket, state)
  end

  defp resume_socket(socket, state) do
    # The socket backend can report udp_closed after a receive error while the
    # socket is still usable, but passive. The inet backend may remain active.
    case :inet.setopts(socket, active: true) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:udp_rearm_failed, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %State{meta: {_, _, socket, _, _}}) do
    :gen_udp.close(socket)
    :ok
  end

  # Construct iodata representing packet to send
  defp heartbeat(node_name, %State{meta: {_, _, _, secret, _}})
       when is_nil(secret) do
    ["heartbeat::", :erlang.term_to_binary(%{node: node_name})]
  end

  defp heartbeat(node_name, %State{meta: {_, _, _, secret, _}} = state) when is_binary(secret) do
    message = "heartbeat::" <> :erlang.term_to_binary(%{node: node_name})
    {:ok, iv, msg} = encrypt(state, message, secret)

    [iv, msg]
  end

  # Upon receipt of a heartbeat, we check to see if the node
  # is connected to us, and if not, we connect to it.
  # If the connection fails, it's likely because the cookie
  # is different, and thus a node we can ignore
  @spec handle_heartbeat(State.t(), binary) :: State.t()
  defp handle_heartbeat(%State{} = state, <<"heartbeat::", rest::binary>>) do
    with {:ok, name} <- decode_heartbeat(rest),
         false <- name == Atom.to_string(node()),
         {:ok, n, state} <- node_name_to_atom(state, name) do
      debug(state.topology, "received heartbeat from #{n}")
      Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, [n])
      state
    else
      _ -> state
    end
  end

  defp handle_heartbeat(state, _packet) do
    state
  end

  # The payload comes from whoever can reach the socket, so it is matched against the one
  # shape our sender produces (the external term format of `%{node: name}`) and never handed
  # to `:erlang.binary_to_term/1,2`. Decoding arbitrary terms would intern every atom the
  # sender names, and the `:safe` option cannot be used because a newly discovered node
  # name is, by definition, an atom this node may not have yet.
  @spec decode_heartbeat(binary) :: {:ok, String.t()} | :error
  defp decode_heartbeat(<<131, 116, 1::32, rest::binary>>) do
    with {:ok, "node", rest} <- decode_atom_text(rest),
         {:ok, name, <<>>} <- decode_atom_text(rest),
         true <- node_name?(name) do
      {:ok, name}
    else
      _ -> :error
    end
  end

  defp decode_heartbeat(_packet), do: :error

  # SMALL_ATOM_UTF8_EXT and ATOM_UTF8_EXT
  defp decode_atom_text(<<119, size, text::binary-size(size), rest::binary>>),
    do: {:ok, text, rest}

  defp decode_atom_text(<<118, size::16, text::binary-size(size), rest::binary>>),
    do: {:ok, text, rest}

  # ATOM_EXT and SMALL_ATOM_EXT carry Latin-1 text; OTP releases before 26 send them.
  defp decode_atom_text(<<100, size::16, text::binary-size(size), rest::binary>>),
    do: {:ok, :unicode.characters_to_binary(text, :latin1), rest}

  defp decode_atom_text(<<115, size, text::binary-size(size), rest::binary>>),
    do: {:ok, :unicode.characters_to_binary(text, :latin1), rest}

  defp decode_atom_text(_packet), do: :error

  # Distribution only accepts names with exactly one "@" between a name and a host.
  defp node_name?(name) do
    with true <- String.valid?(name),
         true <- String.length(name) <= @max_atom_characters,
         [node_name, host] when node_name != "" and host != "" <-
           :binary.split(name, "@", [:global]) do
      true
    else
      _ -> false
    end
  end

  # Atoms are never collected, so only a bounded number of names this node has not seen
  # before are turned into atoms. Names that already exist cost nothing and always resolve.
  defp node_name_to_atom(%State{} = state, name) do
    {:ok, String.to_existing_atom(name), state}
  rescue
    ArgumentError -> new_node_name_to_atom(state, name)
  end

  defp new_node_name_to_atom(%State{meta: {_, _, _, _, 0}}, _name), do: :error

  defp new_node_name_to_atom(%State{meta: meta} = state, name) do
    remaining = elem(meta, 4) - 1

    if remaining == 0 do
      warn(
        state.topology,
        "max_new_node_names reached; ignoring heartbeats from node names not already known"
      )
    end

    {:ok, String.to_atom(name), %State{state | meta: put_elem(meta, 4, remaining)}}
  end

  defp encrypt(_state, plaintext, password) do
    iv = :crypto.strong_rand_bytes(16)
    key = :crypto.hash(:sha256, password)
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, pkcs7_pad(plaintext), true)

    {:ok, iv, ciphertext}
  end

  defp decrypt(_state, ciphertext, password, iv)
       when byte_size(ciphertext) > 0 and rem(byte_size(ciphertext), 16) == 0 do
    key = :crypto.hash(:sha256, password)
    padded = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)

    case pkcs7_unpad(padded) do
      {:ok, _plaintext} = result -> result
      :error -> {:error, :unpadding}
    end
  end

  defp decrypt(_state, _ciphertext, _password, _iv), do: {:error, :decrypt}

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

    message_size = byte_size(message)

    if padding_size in 1..16 and padding_size <= message_size do
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
