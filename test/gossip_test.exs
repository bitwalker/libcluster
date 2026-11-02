defmodule Cluster.Strategy.GossipTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy.Gossip
  alias Cluster.Strategy.State

  import ExUnit.CaptureLog

  describe "start_link/1" do
    @tag capture_log: true
    test "continues discovering peers after malformed datagrams" do
      initial = %{
        state()
        | config: [
            port: 0,
            if_addr: "127.0.0.1",
            multicast_addr: "127.0.0.1",
            broadcast_only: true
          ]
      }

      pid = start_supervised!({Gossip, [initial]})
      send(pid, {:udp, nil, {127, 0, 0, 1}, 1, <<"heartbeat::", 0>>})
      send(pid, {:udp, nil, {127, 0, 0, 1}, 1, heartbeat(%{node: :"peer@127.0.0.2"})})

      assert_receive {:connect, :"peer@127.0.0.2"}
      assert %State{} = :sys.get_state(pid)
    end

    @tag capture_log: true
    test "delivers a multicast heartbeat to both instances sharing a port" do
      interface = multicast_interface()

      config = [
        port: 0,
        if_addr: "0.0.0.0",
        multicast_if: interface,
        multicast_ttl: 0,
        multicast_addr: "233.252.1.32"
      ]

      first_state = %{
        state()
        | config: config,
          connect: {__MODULE__, :record_connection, [self(), :first]}
      }

      first = start_supervised!({Gossip, [first_state]}, id: :first)
      %State{meta: {_, _, socket, _}} = :sys.get_state(first)
      {:ok, port} = :inet.port(socket)

      if match?({:win32, _}, :os.type()) do
        # Named getters report the driver's cached flags. Check Winsock itself
        # before binding another socket, so a failure identifies the real state.
        native = :inet.getopts(socket, [{:raw, 0xFFFF, 0x0004, 4}])

        assert native == {:ok, [{:raw, 0xFFFF, 0x0004, <<1::native-32>>}]}
      end

      second_config = Keyword.put(config, :port, port)

      second_state = %{
        state()
        | config: second_config,
          connect: {__MODULE__, :record_connection, [self(), :second]}
      }

      start_supervised!({Gossip, [second_state]}, id: :second)

      {:ok, sender} =
        :gen_udp.open(0, multicast_if: interface, multicast_loop: true, multicast_ttl: 0)

      on_exit(fn -> :gen_udp.close(sender) end)
      packet = heartbeat(%{node: :"multicast-peer@127.0.0.2"})
      :ok = :gen_udp.send(sender, {233, 252, 1, 32}, port, packet)

      assert_receive {:connect, :first, :"multicast-peer@127.0.0.2"}, 5_000
      assert_receive {:connect, :second, :"multicast-peer@127.0.0.2"}, 5_000
    end

    test "returns bind failure with port and interface context" do
      # Windows requires exclusiveaddruse to prevent a reuse-enabled socket from
      # sharing the blocker. Other platforms use the ordinary exclusive bind.
      exclusive =
        if match?({:win32, _}, :os.type()) and String.to_integer(System.otp_release()) >= 26,
          do: [exclusiveaddruse: true],
          else: []

      {:ok, blocker} = :gen_udp.open(0, [ip: {127, 0, 0, 1}, reuseaddr: false] ++ exclusive)
      on_exit(fn -> :gen_udp.close(blocker) end)
      {:ok, port} = :inet.port(blocker)

      initial = %{state() | config: [port: port, if_addr: "127.0.0.1", broadcast_only: true]}

      assert {:stop, {:udp_open_failed, reason, [port: ^port, if_addr: {127, 0, 0, 1}]}} =
               Gossip.init([initial])

      assert reason in [:eaddrinuse, :eacces]
    end
  end

  for notification <- [:udp_error, :udp_closed] do
    @tag capture_log: true
    test "resumes real UDP reception after #{notification}" do
      initial = %{
        state()
        | config: [
            port: 0,
            if_addr: "127.0.0.1",
            multicast_addr: "127.0.0.1",
            broadcast_only: true
          ]
      }

      server = start_supervised!({Gossip, [initial]})
      %State{meta: {_, _, socket, _}} = :sys.get_state(server)
      {:ok, port} = :inet.port(socket)
      :ok = :inet.setopts(socket, active: false)

      message =
        case unquote(notification) do
          :udp_error -> {:udp_error, socket, :econnreset}
          :udp_closed -> {:udp_closed, socket}
        end

      send(server, message)
      assert %State{meta: {_, _, ^socket, _}} = :sys.get_state(server)
      assert {:ok, [active: true]} = :inet.getopts(socket, [:active])

      {:ok, sender} = :gen_udp.open(0, [:binary, active: false])
      on_exit(fn -> :gen_udp.close(sender) end)

      :ok =
        :gen_udp.send(sender, {127, 0, 0, 1}, port, heartbeat(%{node: :"recovered@127.0.0.2"}))

      assert_receive {:connect, :"recovered@127.0.0.2"}, 5_000

      {:ok, {_, destination}} = :inet.sockname(sender)

      :sys.replace_state(server, fn current ->
        %{current | meta: {{127, 0, 0, 1}, destination, socket, nil}}
      end)

      send(server, :heartbeat)
      assert {:ok, {_, ^port, <<"heartbeat::", _::binary>>}} = :gen_udp.recv(sender, 0, 5_000)
    end
  end

  test "stops with a useful reason when the UDP socket cannot be rearmed" do
    {:ok, socket} = :gen_udp.open(0, active: false)
    :ok = :gen_udp.close(socket)
    current = %{state() | meta: {{127, 0, 0, 1}, 12345, socket, nil}}

    assert {:stop, {:udp_rearm_failed, reason}, ^current} =
             Gossip.handle_info({:udp_closed, socket}, current)

    assert reason in [:closed, :einval]
  end

  def record_connection(caller, instance, node) do
    send(caller, {:connect, instance, node})
    true
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

  test "ignores invalid plaintext terms and trailing data" do
    valid = heartbeat(%{node: :"peer@127.0.0.2"})

    for packet <- [
          <<"heartbeat::", 0>>,
          "heartbeat::",
          valid <> <<0>>,
          heartbeat(%{node: "not an atom"}),
          heartbeat([:invalid])
        ] do
      assert {:noreply, unchanged} = Gossip.handle_info({:udp, nil, nil, 0, packet}, state())
      assert unchanged == state()
    end

    refute_receive {:connect, _}
  end

  test "rejects compressed terms before decompression" do
    packet =
      "heartbeat::" <>
        :erlang.term_to_binary(%{node: :"peer@127.0.0.2", padding: :binary.copy(<<0>>, 4096)}, [
          :compressed
        ])

    assert {:noreply, _} = Gossip.handle_info({:udp, nil, nil, 0, packet}, state())
    refute_receive {:connect, _}
  end

  test "still discovers a previously unknown node atom" do
    name = "new-peer-#{System.unique_integer([:positive])}@127.0.0.2"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    # The existing wire format uses a map with atom key and atom node identity.
    packet =
      <<"heartbeat::", 131, 116, 1::32, 119, 4, "node", 118, byte_size(name)::16, name::binary>>

    assert {:noreply, _} = Gossip.handle_info({:udp, nil, nil, 0, packet}, state())
    node = String.to_existing_atom(name)
    assert_receive {:connect, ^node}
  end

  test "ignores malformed encrypted packets and then accepts a valid heartbeat" do
    secret = "password"
    encrypted_state = state(secret)

    capture_log(fn ->
      for packet <- [
            <<0>>,
            <<0::128>>,
            <<0::128, 1>>,
            encrypt(<<"heartbeat::", 0>>, secret),
            encrypt_padded(<<0::128>>, secret)
          ] do
        assert {:noreply, ^encrypted_state} =
                 Gossip.handle_info({:udp, nil, nil, 0, packet}, encrypted_state)
      end
    end)

    refute_receive {:connect, _}
    valid = encrypt(heartbeat(%{node: :"peer@127.0.0.2"}), secret)

    assert {:noreply, ^encrypted_state} =
             Gossip.handle_info({:udp, nil, nil, 0, valid}, encrypted_state)

    assert_receive {:connect, :"peer@127.0.0.2"}
  end

  test "rejects invalid PKCS7 padding lengths" do
    encrypted_state = state("password")
    message = heartbeat(%{node: :"peer@127.0.0.2"})

    for padding <- [0, 17, 255] do
      padded = message <> :binary.copy(<<padding>>, 16 - rem(byte_size(message), 16))
      packet = encrypt_padded(padded, "password")

      assert {:noreply, ^encrypted_state} =
               Gossip.handle_info({:udp, nil, nil, 0, packet}, encrypted_state)
    end

    refute_receive {:connect, _}
  end

  defp state(secret \\ nil) do
    %State{
      topology: :gossip,
      meta: {nil, nil, nil, secret},
      connect: {Cluster.Nodes, :connect, [self()]},
      list_nodes: {Cluster.Nodes, :list_nodes, [[]]}
    }
  end

  defp heartbeat(term), do: "heartbeat::" <> :erlang.term_to_binary(term)

  defp encrypt(message, secret) do
    padding = 16 - rem(byte_size(message), 16)
    encrypt_padded(message <> :binary.copy(<<padding>>, padding), secret)
  end

  defp encrypt_padded(message, secret) do
    iv = :crypto.strong_rand_bytes(16)
    iv <> :crypto.crypto_one_time(:aes_256_cbc, :crypto.hash(:sha256, secret), iv, message, true)
  end
end
