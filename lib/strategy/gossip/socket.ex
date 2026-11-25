defmodule Cluster.Strategy.Gossip.Socket do
  @moduledoc false
  # UDP socket setup shared by the gossip strategies.

  @default_port 45892
  @default_addr {0, 0, 0, 0}
  @default_multicast_addr {233, 252, 1, 32}
  @sol_socket 0xFFFF
  @so_reuseport 0x0200
  @windows_so_reuseaddr 0x0004

  @type context :: [port: :inet.port_number(), if_addr: :inet.ip4_address()]

  @doc """
  Opens the gossip socket described by a strategy's `config`.

  `active` is the socket's initial active mode. Returns the socket together with the
  address and port heartbeats are sent to.
  """
  @spec open(keyword, true | :once) ::
          {:ok, :gen_udp.socket(), :inet.ip4_address(), :inet.port_number()}
          | {:error, term, context}
  def open(config, active) do
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
        active: active,
        ip: ip,
        reuseaddr: true,
        broadcast: true
      ] ++ multicast_opts ++ reuse_port()

    case :gen_udp.open(port, options) do
      {:ok, socket} -> {:ok, socket, multicast_addr, port}
      {:error, reason} -> {:error, reason, [port: port, if_addr: ip]}
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
end
