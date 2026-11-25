defmodule Cluster.Strategy.AuthenticatedGossip do
  @moduledoc """
  This clustering strategy gossips node names over multicast UDP, like
  `Cluster.Strategy.Gossip`, but every heartbeat is encrypted and authenticated. Use it
  when hosts you do not control can reach the gossip port.

  A heartbeat is only acted on if it was sealed by a node holding the same key, carries a
  timestamp close to the local clock, and is newer than the last heartbeat accepted from
  that node. Anything else is dropped before it is parsed: it creates no atoms, starts no
  connection attempts and leaves no state behind.

  ## Key

  The key is derived from the `secret` option. Without a `secret`, it is derived from the
  node's Erlang cookie, so nodes that are able to connect to each other can also discover
  each other with no further configuration. The cookie is read again at every heartbeat,
  so a changed cookie takes effect within a few seconds. A node that has neither a secret
  nor a cookie (distribution is not started) neither announces itself nor accepts
  heartbeats.

  Configure a `secret` if you use per-node cookies, or if the cookie is weak: a recorded
  heartbeat lets someone test guesses for the key material offline, as a recorded
  distribution handshake does for the cookie.

  ## Clocks

  Heartbeats carry the sender's system time. A heartbeat is ignored if that time differs
  from the receiver's clock by more than `max_clock_skew` milliseconds (30,000 by default),
  which is what stops recorded heartbeats from being replayed later. Nodes therefore need
  roughly synchronized clocks. When an authentic heartbeat is ignored for this reason a
  warning is logged, at most once a minute.

  ## What this does not protect against

  Anyone holding the secret or cookie is trusted to announce any node name. Someone able to
  saturate the network or the socket's receive buffer can delay discovery for as long as
  they keep it up; excess datagrams are dropped by the operating system rather than queued
  in the VM.

  This strategy does not interoperate with `Cluster.Strategy.Gossip`. Both may use the same
  port and multicast address; each ignores the other's packets.

  ## Configuration

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
              max_clock_skew: 30_000]]]

  `port`, `if_addr`, `multicast_if`, `multicast_addr`, `multicast_ttl` and `broadcast_only`
  behave as they do for `Cluster.Strategy.Gossip`, including port sharing between nodes on
  one host and the `{:udp_open_failed, reason, [port: port, if_addr: address]}` stop reason.

  ## Wire format

      "LCAG" | version (1) | nonce (12 bytes) | ciphertext | tag (16 bytes)

  The ciphertext is AES-256-GCM over a 64-bit millisecond timestamp followed by the node
  name in UTF-8, with the first five bytes as associated data. The key is HKDF-SHA-256 of
  the secret or cookie.
  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.Gossip.Socket
  alias Cluster.Strategy.State

  @header <<"LCAG", 1>>
  @nonce_size 12
  @tag_size 16
  @max_atom_characters 255
  # The shortest node name is "a@b"; the longest is 255 four-byte characters.
  @min_packet byte_size(@header) + @nonce_size + 8 + 3 + @tag_size
  @max_packet byte_size(@header) + @nonce_size + 8 + 4 * @max_atom_characters + @tag_size
  @key_salt "libcluster authenticated gossip v1"
  @key_info <<"aes-256-gcm", 1>>
  @default_max_clock_skew 30_000
  @skew_warning_interval 60_000

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init([%State{config: config} = state]) do
    secret = secret!(config)
    max_clock_skew = max_clock_skew!(config)

    # The socket is read one datagram at a time, so datagrams arriving faster than they
    # are handled wait in, or overflow, the kernel buffer instead of this process's mailbox.
    case Socket.open(config, :once) do
      {:ok, socket, multicast_addr, port} ->
        meta =
          refresh_key(%{
            socket: socket,
            addr: multicast_addr,
            port: port,
            key: secret && derive_key(secret),
            key_source: secret && :secret,
            max_clock_skew: max_clock_skew,
            # node name => timestamp of the newest heartbeat accepted from it
            seen: %{},
            # monitor of a running connection attempt => the node it connects to
            connecting: %{},
            skew_warned_at: nil
          })

        {:ok, %State{state | meta: meta}, {:continue, nil}}

      {:error, reason, context} ->
        {:stop, {:udp_open_failed, reason, context}}
    end
  end

  defp secret!(config) do
    case Keyword.get(config, :secret) do
      nil -> nil
      secret when is_binary(secret) and secret != "" -> secret
      # The value is deliberately left out of the message.
      _ -> raise ArgumentError, "expected :secret to be a non-empty binary"
    end
  end

  defp max_clock_skew!(config) do
    case Keyword.get(config, :max_clock_skew, @default_max_clock_skew) do
      skew when is_integer(skew) and skew > 0 ->
        skew

      other ->
        raise ArgumentError,
              "expected :max_clock_skew to be a positive integer, got: #{inspect(other)}"
    end
  end

  # Send stuttered heartbeats
  @impl true
  def handle_continue(_, state), do: handle_info(:heartbeat, state)

  @impl true
  def handle_info(:heartbeat, %State{meta: meta} = state) do
    now = System.os_time(:millisecond)
    meta = meta |> refresh_key() |> forget_expired(now)
    announce(meta, state.topology, now)
    Process.send_after(self(), :heartbeat, :rand.uniform(5_000))
    {:noreply, %State{state | meta: meta}}
  end

  def handle_info({:udp, socket, _ip, _port, packet}, %State{meta: %{socket: socket}} = state) do
    packet
    |> handle_packet(state)
    |> resume_socket()
  end

  def handle_info({:udp_error, socket, reason}, %State{meta: %{socket: socket}} = state) do
    warn(state.topology, "UDP receive error: #{inspect(reason)}")
    resume_socket(state)
  end

  def handle_info({:udp_closed, socket}, %State{meta: %{socket: socket}} = state) do
    resume_socket(state)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{meta: meta} = state) do
    {:noreply, %State{state | meta: %{meta | connecting: Map.delete(meta.connecting, ref)}}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{meta: %{socket: socket}}) do
    :gen_udp.close(socket)
    :ok
  end

  defp resume_socket(%State{meta: %{socket: socket}} = state) do
    case :inet.setopts(socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:udp_rearm_failed, reason}, state}
    end
  end

  ## Key

  defp refresh_key(%{key_source: :secret} = meta), do: meta

  defp refresh_key(%{key_source: source} = meta) do
    case :erlang.get_cookie() do
      :nocookie -> %{meta | key: nil, key_source: nil}
      cookie when source == {:cookie, cookie} -> meta
      cookie -> %{meta | key: derive_key(Atom.to_string(cookie)), key_source: {:cookie, cookie}}
    end
  end

  # HKDF-SHA-256 (RFC 5869), producing a single 32-byte block.
  defp derive_key(secret) do
    extracted = :crypto.mac(:hmac, :sha256, @key_salt, secret)
    :crypto.mac(:hmac, :sha256, extracted, @key_info)
  end

  ## Sending

  defp announce(%{key: nil}, topology, _now) do
    debug(topology, "no secret or cookie available, not announcing")
  end

  defp announce(%{key: key, socket: socket, addr: addr, port: port}, topology, now) do
    debug(topology, "heartbeat")
    _ = :gen_udp.send(socket, addr, port, seal(key, Atom.to_string(node()), now))
    :ok
  end

  defp seal(key, name, timestamp) do
    nonce = :crypto.strong_rand_bytes(@nonce_size)
    plaintext = <<timestamp::64, name::binary>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, @header, @tag_size, true)

    [@header, nonce, ciphertext, tag]
  end

  ## Receiving

  # Nothing in a datagram is looked at, beyond its header and size, until its tag verifies.
  defp handle_packet(packet, %State{meta: %{key: key}} = state) when is_binary(key) do
    case open(key, packet) do
      {:ok, timestamp, name} -> handle_heartbeat(state, name, timestamp)
      :error -> state
    end
  end

  defp handle_packet(_packet, state), do: state

  defp open(key, <<@header, nonce::binary-size(@nonce_size), sealed::binary>> = packet)
       when byte_size(packet) >= @min_packet and byte_size(packet) <= @max_packet do
    ciphertext_size = byte_size(sealed) - @tag_size
    ciphertext = binary_part(sealed, 0, ciphertext_size)
    tag = binary_part(sealed, ciphertext_size, @tag_size)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @header, tag, false) do
      <<timestamp::64, name::binary>> -> {:ok, timestamp, name}
      :error -> :error
    end
  end

  defp open(_key, _packet), do: :error

  defp handle_heartbeat(%State{meta: meta} = state, name, timestamp) do
    skew = abs(System.os_time(:millisecond) - timestamp)

    cond do
      not node_name?(name) ->
        state

      name == Atom.to_string(node()) ->
        state

      skew > meta.max_clock_skew ->
        warn_skew(state, name, skew)

      # A copy of a heartbeat already accepted, or one sent before it.
      timestamp <= Map.get(meta.seen, name, -1) ->
        state

      true ->
        debug(state.topology, "received heartbeat from #{name}")
        seen = Map.put(meta.seen, name, timestamp)
        # Only a key holder can get a name this far, so it is safe to create the atom.
        connect(%State{state | meta: %{meta | seen: seen}}, String.to_atom(name))
    end
  end

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

  defp warn_skew(%State{meta: meta} = state, name, skew) do
    monotonic = System.monotonic_time(:millisecond)
    last = meta.skew_warned_at

    if is_nil(last) or monotonic - last >= @skew_warning_interval do
      warn(
        state.topology,
        "ignoring authentic heartbeat from #{inspect(name)}: its timestamp is #{skew} ms " <>
          "from the local clock, more than max_clock_skew (#{meta.max_clock_skew} ms). " <>
          "Check clock synchronization; a replayed heartbeat also causes this"
      )

      %State{state | meta: %{meta | skew_warned_at: monotonic}}
    else
      state
    end
  end

  # An entry older than this would be rejected for its timestamp alone.
  defp forget_expired(%{seen: seen, max_clock_skew: max_clock_skew} = meta, now) do
    oldest = now - max_clock_skew
    %{meta | seen: :maps.filter(fn _name, timestamp -> timestamp >= oldest end, seen)}
  end

  # A connection attempt to an unreachable host can take seconds, so it runs outside the
  # receive loop. One attempt per node at a time keeps heartbeats from piling attempts up.
  defp connect(%State{meta: meta} = state, node) do
    if node in Map.values(meta.connecting) do
      state
    else
      %State{topology: topology, connect: connect, list_nodes: list_nodes} = state

      {_pid, ref} =
        :erlang.spawn_opt(
          fn -> Cluster.Strategy.connect_nodes(topology, connect, list_nodes, [node]) end,
          [:link, :monitor]
        )

      %State{state | meta: %{meta | connecting: Map.put(meta.connecting, ref, node)}}
    end
  end
end
