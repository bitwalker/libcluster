defmodule Cluster.Strategy.GossipTest do
  @moduledoc false

  use ExUnit.Case

  alias Cluster.Strategy.Gossip
  alias Cluster.Strategy.State

  import ExUnit.CaptureLog

  require Cluster.Nodes

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
