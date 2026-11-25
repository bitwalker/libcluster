defmodule Cluster.Strategy.AuthenticatedGossipTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.LocalPeer
  alias Cluster.Strategy.AuthenticatedGossip
  alias Cluster.Strategy.State

  import ExUnit.CaptureLog

  @moduletag capture_log: true

  @secret "a shared secret"
  @header <<"LCAG", 1>>

  describe "authenticated heartbeats" do
    test "connects to a previously unknown node named by a fresh heartbeat" do
      state = init!()
      name = fresh_name()

      state = deliver(state, seal(@secret, name, now()))

      node = String.to_existing_atom(name)
      assert_receive {:connect, ^node}
      assert %State{} = state
    end

    test "ignores heartbeats sealed with a different secret" do
      state = init!()
      name = fresh_name()

      deliver(state, seal("another secret", name, now()))

      refute_receive {:connect, _}
      refute_interned([name])
    end

    test "ignores heartbeats altered in any part" do
      state = init!()
      name = fresh_name()
      packet = seal(@secret, name, now())

      # header version, nonce, timestamp, name, tag
      for offset <- [4, 5, 17, 25, byte_size(packet) - 1] do
        deliver(state, flip_bit(packet, offset))
      end

      deliver(state, binary_part(packet, 0, byte_size(packet) - 1))
      deliver(state, packet <> <<0>>)

      refute_receive {:connect, _}
      refute_interned([name])
    end

    test "ignores heartbeats bound to a different header" do
      state = init!()
      name = fresh_name()

      deliver(state, seal(@secret, name, now(), <<"LCAG", 2>>))

      refute_receive {:connect, _}
      refute_interned([name])
    end

    test "ignores plaintext Gossip heartbeats and arbitrary datagrams" do
      state = init!()
      name = fresh_name()

      plaintext =
        <<"heartbeat::", 131, 116, 1::32, 119, 4, "node", 119, byte_size(name), name::binary>>

      for packet <- [plaintext, <<>>, @header, :crypto.strong_rand_bytes(64), <<0::16_000>>] do
        deliver(state, packet)
      end

      refute_receive {:connect, _}
      refute_interned([name])
    end

    test "ignores authenticated names that are not node names" do
      state = init!()

      names = [
        fresh_name(""),
        fresh_name("@"),
        "@" <> fresh_name(""),
        fresh_name("@127.0.0.2@127.0.0.3"),
        fresh_name("@" <> String.duplicate("a", 255)),
        fresh_name("@127.0.0.2") <> <<0xFF>>
      ]

      for name <- names, do: deliver(state, seal(@secret, name, now()))

      refute_receive {:connect, _}
      refute_interned(Enum.filter(names, &String.valid?/1))
    end

    test "ignores its own heartbeat" do
      state = init!()

      deliver(state, seal(@secret, Atom.to_string(node()), now()))

      refute_receive {:connect, _}
    end
  end

  describe "freshness" do
    test "accepts heartbeats within max_clock_skew of the local clock" do
      state = init!()
      [behind, ahead] = [fresh_name(), fresh_name()]

      state = deliver(state, seal(@secret, behind, now() - 25_000))
      deliver(state, seal(@secret, ahead, now() + 25_000))

      for name <- [behind, ahead] do
        node = String.to_existing_atom(name)
        assert_receive {:connect, ^node}
      end
    end

    test "ignores heartbeats older or newer than max_clock_skew" do
      state = init!()
      names = [fresh_name(), fresh_name()]
      [behind, ahead] = names

      state = deliver(state, seal(@secret, behind, now() - 35_000))
      deliver(state, seal(@secret, ahead, now() + 35_000))

      refute_receive {:connect, _}
      refute_interned(names)
    end

    test "honors a configured max_clock_skew" do
      state = init!(max_clock_skew: 1_000)
      name = fresh_name()

      deliver(state, seal(@secret, name, now() - 5_000))

      refute_receive {:connect, _}
      refute_interned([name])
    end

    test "warns once about authentic heartbeats outside max_clock_skew" do
      state = init!()

      log =
        capture_log(fn ->
          state = deliver(state, seal(@secret, fresh_name(), now() - 35_000))
          deliver(state, seal(@secret, fresh_name(), now() - 35_000))
        end)

      assert [_before, _after] = String.split(log, "max_clock_skew")
    end

    test "does not warn about datagrams that fail authentication" do
      state = init!()

      log =
        capture_log(fn ->
          deliver(state, seal("another secret", fresh_name(), now() - 35_000))
        end)

      assert log == ""
    end
  end

  describe "replay" do
    test "ignores a heartbeat it has already accepted" do
      state = init!()
      name = fresh_name()
      packet = seal(@secret, name, now())

      state = deliver(state, packet)
      node = String.to_existing_atom(name)
      assert_receive {:connect, ^node}
      state = await_connection_attempt(state)

      deliver(state, packet)
      refute_receive {:connect, _}
    end

    test "ignores a heartbeat older than the newest one accepted for that node" do
      state = init!()
      name = fresh_name()
      timestamp = now()

      state = deliver(state, seal(@secret, name, timestamp))
      node = String.to_existing_atom(name)
      assert_receive {:connect, ^node}
      state = await_connection_attempt(state)

      state = deliver(state, seal(@secret, name, timestamp - 1))
      refute_receive {:connect, _}

      deliver(state, seal(@secret, name, timestamp + 1))
      assert_receive {:connect, ^node}
    end

    test "forgets accepted heartbeats once they could no longer pass the freshness check" do
      state = init!(max_clock_skew: 100)

      state = deliver(state, seal(@secret, fresh_name(), now()))
      assert map_size(state.meta.seen) == 1

      Process.sleep(150)
      assert {:noreply, state} = AuthenticatedGossip.handle_info(:heartbeat, state)
      assert map_size(state.meta.seen) == 0
    end
  end

  describe "connection attempts" do
    test "do not block reception, and are not repeated while one is in flight" do
      state = init!(connect: {__MODULE__, :blocking_connect, [self()]})
      [slow, other] = [fresh_name(), fresh_name()]
      timestamp = now()

      state = deliver(state, seal(@secret, slow, timestamp))
      slow_node = String.to_existing_atom(slow)
      assert_receive {:connecting, ^slow_node, attempt}

      state = deliver(state, seal(@secret, slow, timestamp + 1))
      refute_receive {:connecting, ^slow_node, _}

      state = deliver(state, seal(@secret, other, timestamp))
      other_node = String.to_existing_atom(other)
      assert_receive {:connecting, ^other_node, other_attempt}

      send(attempt, :release)
      send(other_attempt, :release)
      state = state |> await_connection_attempt() |> await_connection_attempt()

      deliver(state, seal(@secret, slow, timestamp + 2))
      assert_receive {:connecting, ^slow_node, again}
      send(again, :release)
    end
  end

  describe "sending" do
    test "announces this node in a sealed heartbeat carrying the current time" do
      {state, listener} = init_with_listener!()

      assert {:noreply, _} = AuthenticatedGossip.handle_info(:heartbeat, state)

      assert {:ok, {_, _, packet}} = :gen_udp.recv(listener, 0, 1_000)
      assert {:ok, timestamp, name} = open(@secret, packet)
      assert name == Atom.to_string(node())
      assert_in_delta timestamp, now(), 5_000
      assert_receive :heartbeat, 6_000
    end

    test "uses a new nonce for every heartbeat" do
      {state, listener} = init_with_listener!()

      nonces =
        for _ <- 1..3 do
          assert {:noreply, _} = AuthenticatedGossip.handle_info(:heartbeat, state)

          assert {:ok, {_, _, <<@header, nonce::binary-12, _::binary>>}} =
                   :gen_udp.recv(listener, 0, 1_000)

          nonce
        end

      assert length(Enum.uniq(nonces)) == 3
    end
  end

  describe "without a secret" do
    setup :distribute

    test "keys heartbeats with the Erlang cookie" do
      cookie = Atom.to_string(Node.get_cookie())
      {state, listener} = init_with_listener!(secret: nil)

      assert {:noreply, state} = AuthenticatedGossip.handle_info(:heartbeat, state)
      assert {:ok, {_, _, packet}} = :gen_udp.recv(listener, 0, 1_000)
      assert {:ok, _timestamp, name} = open(cookie, packet)
      assert name == Atom.to_string(node())

      peer = fresh_name()
      deliver(state, seal(cookie, peer, now()))
      node = String.to_existing_atom(peer)
      assert_receive {:connect, ^node}
    end

    test "follows a cookie change at the next heartbeat" do
      old_cookie = Atom.to_string(Node.get_cookie())
      {state, listener} = init_with_listener!(secret: nil)

      Node.set_cookie(:a_rotated_cookie)
      assert {:noreply, state} = AuthenticatedGossip.handle_info(:heartbeat, state)
      assert {:ok, {_, _, packet}} = :gen_udp.recv(listener, 0, 1_000)
      assert {:ok, _, _} = open("a_rotated_cookie", packet)

      stale = fresh_name()
      state = deliver(state, seal(old_cookie, stale, now()))
      refute_receive {:connect, _}
      refute_interned([stale])

      current = fresh_name()
      deliver(state, seal("a_rotated_cookie", current, now()))
      node = String.to_existing_atom(current)
      assert_receive {:connect, ^node}
    end
  end

  describe "without a secret or a cookie" do
    test "stays silent and ignores every heartbeat" do
      assert Node.get_cookie() == :nocookie
      {state, listener} = init_with_listener!(secret: nil)
      name = fresh_name()

      assert {:noreply, state} = AuthenticatedGossip.handle_info(:heartbeat, state)
      assert {:error, :timeout} = :gen_udp.recv(listener, 0, 200)

      deliver(state, seal("nocookie", name, now()))
      refute_receive {:connect, _}
      refute_interned([name])
    end
  end

  describe "socket" do
    test "takes one datagram at a time, so a flood stays in the kernel buffer" do
      state = init!()
      socket = state.meta.socket
      {:ok, port} = :inet.port(socket)
      assert {:ok, [active: :once]} = :inet.getopts(socket, [:active])

      {:ok, sender} = :gen_udp.open(0, [:binary, active: false])
      on_exit(fn -> :gen_udp.close(sender) end)
      name = fresh_name()
      :ok = :gen_udp.send(sender, {127, 0, 0, 1}, port, seal(@secret, name, now()))
      :ok = :gen_udp.send(sender, {127, 0, 0, 1}, port, "junk")

      assert_receive {:udp, ^socket, _, _, _} = first, 1_000
      refute_receive {:udp, ^socket, _, _, _}
      assert {:ok, [active: false]} = :inet.getopts(socket, [:active])

      assert {:noreply, state} = AuthenticatedGossip.handle_info(first, state)
      node = String.to_existing_atom(name)
      assert_receive {:connect, ^node}

      assert_receive {:udp, ^socket, _, _, "junk"} = second, 1_000
      assert {:noreply, _} = AuthenticatedGossip.handle_info(second, state)
      assert {:ok, [active: :once]} = :inet.getopts(socket, [:active])
    end

    for notification <- [:udp_error, :udp_closed] do
      test "resumes reception after #{notification}" do
        state = init!()
        socket = state.meta.socket
        :ok = :inet.setopts(socket, active: false)

        message =
          case unquote(notification) do
            :udp_error -> {:udp_error, socket, :econnreset}
            :udp_closed -> {:udp_closed, socket}
          end

        assert {:noreply, ^state} = AuthenticatedGossip.handle_info(message, state)
        assert {:ok, [active: :once]} = :inet.getopts(socket, [:active])
      end
    end

    test "stops with a useful reason when the socket cannot be rearmed" do
      state = init!()
      :ok = :gen_udp.close(state.meta.socket)

      assert {:stop, {:udp_rearm_failed, reason}, ^state} =
               AuthenticatedGossip.handle_info({:udp_closed, state.meta.socket}, state)

      assert reason in [:closed, :einval]
    end

    test "returns bind failure with port and interface context" do
      exclusive =
        if match?({:win32, _}, :os.type()) and String.to_integer(System.otp_release()) >= 26,
          do: [exclusiveaddruse: true],
          else: []

      {:ok, blocker} = :gen_udp.open(0, [ip: {127, 0, 0, 1}, reuseaddr: false] ++ exclusive)
      on_exit(fn -> :gen_udp.close(blocker) end)
      {:ok, port} = :inet.port(blocker)

      config = Keyword.put([secret: @secret] ++ loopback(), :port, port)

      assert {:stop, {:udp_open_failed, reason, [port: ^port, if_addr: {127, 0, 0, 1}]}} =
               AuthenticatedGossip.init([%{topology() | config: config}])

      assert reason in [:eaddrinuse, :eacces]
    end
  end

  describe "configuration" do
    test "rejects a secret that is not a non-empty binary" do
      for secret <- ["", :secret, 42] do
        assert_raise ArgumentError, ~r/:secret/, fn ->
          AuthenticatedGossip.init([%{topology() | config: [secret: secret] ++ loopback()}])
        end
      end
    end

    test "rejects a max_clock_skew that is not a positive integer" do
      for skew <- [0, -1, 1.5, :infinity] do
        assert_raise ArgumentError, ~r/:max_clock_skew/, fn ->
          config = [secret: @secret, max_clock_skew: skew] ++ loopback()
          AuthenticatedGossip.init([%{topology() | config: config}])
        end
      end
    end
  end

  describe "between nodes" do
    unless Code.ensure_loaded?(:peer),
      do: @describetag(skip: "Local distribution tests require OTP25+ :peer")

    test "nodes sharing a cookie discover each other over multicast" do
      cookie = "authenticated-gossip-#{System.unique_integer([:positive])}"
      unique = System.unique_integer([:positive])
      {first, first_node} = LocalPeer.start(:"ag-first-#{unique}", cookie)
      {second, second_node} = LocalPeer.start(:"ag-second-#{unique}", cookie)

      topologies = [
        authenticated: [
          strategy: AuthenticatedGossip,
          config: [
            port: free_port(),
            if_addr: "0.0.0.0",
            multicast_if: multicast_interface(),
            multicast_ttl: 0,
            multicast_addr: "233.252.1.32"
          ]
        ]
      ]

      LocalPeer.call(first, LocalPeer, :start_discovery, [topologies])
      LocalPeer.call(second, LocalPeer, :start_discovery, [topologies])

      assert :ok = LocalPeer.await_nodes(first, [second_node])
      assert :ok = LocalPeer.await_nodes(second, [first_node])
    end
  end

  def blocking_connect(caller, node) do
    send(caller, {:connecting, node, self()})

    receive do
      :release -> true
    end
  end

  # --- wire format, written out independently of the implementation

  defp key(secret) do
    extracted = :crypto.mac(:hmac, :sha256, "libcluster authenticated gossip v1", secret)
    :crypto.mac(:hmac, :sha256, extracted, <<"aes-256-gcm", 1>>)
  end

  defp seal(secret, name, timestamp, header \\ @header) do
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = <<timestamp::64, name::binary>>

    {body, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(secret), nonce, plaintext, header, true)

    header <> nonce <> body <> tag
  end

  defp open(secret, <<@header, nonce::binary-12, rest::binary>>) do
    body_size = byte_size(rest) - 16
    body = binary_part(rest, 0, body_size)
    tag = binary_part(rest, body_size, 16)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(secret), nonce, body, @header, tag, false) do
      <<timestamp::64, name::binary>> -> {:ok, timestamp, name}
      :error -> :error
    end
  end

  defp flip_bit(packet, offset) do
    <<byte>> = binary_part(packet, offset, 1)
    rest = binary_part(packet, offset + 1, byte_size(packet) - offset - 1)
    binary_part(packet, 0, offset) <> <<:erlang.bxor(byte, 1)>> <> rest
  end

  # --- harness

  defp now, do: System.os_time(:millisecond)

  defp loopback do
    [port: 0, if_addr: "127.0.0.1", multicast_addr: "127.0.0.1", broadcast_only: true]
  end

  defp topology do
    %State{
      topology: :authenticated_gossip,
      connect: {Cluster.Nodes, :connect, [self()]},
      list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
    }
  end

  # Runs the strategy's callbacks in the test process, with a real socket.
  defp init!(options \\ []) do
    {connect, config} = Keyword.pop(options, :connect, {Cluster.Nodes, :connect, [self()]})
    config = Keyword.merge([secret: @secret] ++ loopback(), config)
    config = Enum.reject(config, &match?({:secret, nil}, &1))

    assert {:ok, %State{} = state, {:continue, _}} =
             AuthenticatedGossip.init([%{topology() | config: config, connect: connect}])

    socket = state.meta.socket
    on_exit(fn -> :gen_udp.close(socket) end)
    state
  end

  # Points the strategy's outgoing heartbeats at a socket the test reads from.
  defp init_with_listener!(options \\ []) do
    state = init!(options)
    {:ok, listener} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    {%{state | meta: %{state.meta | port: port}}, listener}
  end

  defp deliver(%State{meta: %{socket: socket}} = state, packet) do
    message = {:udp, socket, {127, 0, 0, 1}, 1, packet}
    assert {:noreply, %State{} = state} = AuthenticatedGossip.handle_info(message, state)
    state
  end

  # The test process stands in for the strategy, so it hands the strategy the
  # notification that a connection attempt finished.
  defp await_connection_attempt(state) do
    assert_receive {:DOWN, _, :process, _, _} = down, 1_000
    assert {:noreply, state} = AuthenticatedGossip.handle_info(down, state)
    state
  end

  defp distribute(_context) do
    _ = :os.cmd(~c"epmd -daemon")
    name = :"ag-test-#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, _} = Node.start(name, :longnames)
    Node.set_cookie(:"ag-cookie-#{System.unique_integer([:positive])}")
    on_exit(fn -> Node.stop() end)
    :ok
  end

  # A name no atom exists for yet. It stays a string so the test does not intern it.
  defp fresh_name(suffix \\ "@127.0.0.2") do
    "ag-fresh-#{System.unique_integer([:positive])}#{suffix}"
  end

  defp refute_interned(names) do
    for name <- names do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_udp.open(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_udp.close(socket)
    port
  end

  defp multicast_interface do
    if match?({:win32, _}, :os.type()) do
      # Windows loopback does not provide the same multicast behavior as Unix.
      # TTL zero keeps the test packet on this host even with a real interface.
      {:ok, interfaces} = :inet.getifaddrs()

      addresses =
        for {_name, properties} <- interfaces,
            :up in Keyword.get(properties, :flags, []),
            :multicast in Keyword.get(properties, :flags, []),
            {:addr, {a, _, _, _} = ip} <- properties,
            a not in [0, 127],
            do: ip

      assert [address | _] = addresses
      address
    else
      {127, 0, 0, 1}
    end
  end
end
