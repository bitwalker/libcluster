defmodule Cluster.Strategy.Gossip do
  @moduledoc """
  This clustering strategy uses multicast UDP to gossip node names
  to other nodes on the network. These packets are listened for on
  each node as well, and a connection will be established between the
  two nodes if they are reachable on the network, and share the same
  magic cookie. In this way, a cluster of nodes may be formed dynamically.

  The gossip protocol is extremely simple, with a prelude followed by the node
  name which sent the packet. The node name is paresed from the packet, and a
  connection attempt is made. It will fail if the two nodes do not share a cookie.

  By default, the gossip occurs on port 45892, using the multicast address 230.1.1.251

  You may configure the multicast address, the interface address to bind to, the port,
  and the TTL of the packets, using the following settings:

      config :libcluster,
        topologies: [
          gossip_example: [
            strategy: #{__MODULE__},
            config: [
              port: 45892,
              if_addr: "0.0.0.0",
              multicast_addr: "230.1.1.251",
              multicast_ttl: 1]]]

  A TTL of 1 will limit packets to the local network, and is the default TTL.
  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_port 45892
  @default_addr {0,0,0,0}
  @default_multicast_addr {230,1,1,251}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      config: Keyword.fetch!(opts, :config)
    }
    port = Keyword.get(state.config, :port, @default_port)
    ip   = Keyword.get(state.config, :if_addr, @default_addr) |> sanitize_ip
    ttl  = Keyword.get(state.config, :multicast_ttl, 1)
    multicast_addr = Keyword.get(state.config, :multicast_addr, @default_multicast_addr) |> sanitize_ip
    {:ok, socket} = :gen_udp.open(port, [
          :binary,
          active: true,
          ip: ip,
          reuseaddr: true,
          broadcast: true,
          multicast_ttl: ttl,
          multicast_loop: true,
          add_membership: {multicast_addr, {0,0,0,0}}
        ])
    state = %{state | :meta => {multicast_addr, port, socket}}
    {:ok, state, 0}
  end

  defp sanitize_ip(input) do
    case input do
      {_a,_b,_c,_d} = ip -> ip
      ip when is_binary(ip) ->
        {:ok, addr} = :inet.parse_ipv4_address(~c"#{ip}")
        addr
    end
  end

  # Send stuttered heartbeats
  def handle_info(:timeout, state), do: handle_info(:heartbeat, state)
  def handle_info(:heartbeat, %State{meta: {multicast_addr, port, socket}} = state) do
    debug state.topology, "heartbeat"
    :ok = :gen_udp.send(socket, multicast_addr, port, heartbeat(node()))
    Process.send_after(self(), :heartbeat, :rand.uniform(5_000))
    {:noreply, state}
  end

  # Handle received heartbeats
  def handle_info({:udp, _socket, _ip, _port, packet}, state) do
    handle_heartbeat(state, packet)
    {:noreply, state}
  end

  def terminate(_type, _reason, %State{meta: {_,_,socket}}) do
    :gen_udp.close(socket)
    :ok
  end

  # Construct iodata representing packet to send
  defp heartbeat(node_name) do
    ["heartbeat::", :erlang.term_to_binary(%{node: node_name})]
  end

  # Upon receipt of a heartbeat, we check to see if the node
  # is connected to us, and if not, we connect to it.
  # If the connection fails, it's likely because the cookie
  # is different, and thus a node we can ignore
  @spec handle_heartbeat(State.t, binary) :: :ok
  defp handle_heartbeat(%State{connect: connect} = state, <<"heartbeat::", rest::binary>>) do
    case :erlang.binary_to_term(rest) do
      %{node: n} when is_atom(n) ->
        debug state.topology, "received heartbeat from #{n}"
        Cluster.Strategy.connect_nodes(state.topology, connect, [n])
        :ok
      _ ->
        :ok
    end
  end
  defp handle_heartbeat(_state, _packet) do
    :ok
  end
end
