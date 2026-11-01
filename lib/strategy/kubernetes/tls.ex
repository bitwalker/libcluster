defmodule Cluster.Strategy.Kubernetes.TLS do
  @moduledoc false

  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  def options(service_account_path, nil, _url) do
    ca = Path.join(service_account_path, "ca.crt")
    {:ok, [ssl: [verify: :verify_peer, cacertfile: String.to_charlist(ca)], timeout: 15_000], []}
  end

  def options(_service_account_path, peer_file, url) when is_binary(peer_file) do
    with {:ok, pem} <- File.read(peer_file),
         {:ok, pins} <- decode_pins(pem) do
      host = url |> URI.parse() |> Map.fetch!(:host) |> String.trim_trailing(".")
      host = String.to_charlist(host)

      reference_id =
        case :inet.parse_address(host) do
          {:ok, ip} -> {:ip, ip}
          {:error, _} -> {:dns_id, host}
        end

      ssl_options = [
        verify: :verify_peer,
        cacerts: [],
        verify_fun: {&verify_peer/3, %{pins: pins, reference_id: reference_id}},
        session_tickets: :disabled
      ]

      # Nonempty per-request socket_opts force a fresh connection in httpc, including
      # when a different caller has already pooled a connection to the same server.
      request_options = [socket_opts: [reuse_sessions: false]]
      {:ok, [ssl: ssl_options, timeout: 15_000, autoredirect: false], request_options}
    else
      {:error, reason} -> {:error, {:peer_cert_file, reason}}
    end
  end

  def options(_, _, _), do: {:error, :invalid_peer_cert_file_setting}

  defp decode_pins(pem) do
    case :public_key.pem_decode(pem) do
      [] ->
        {:error, :empty_peer_cert_file}

      entries ->
        pins =
          Enum.map(entries, fn {:Certificate, der, :not_encrypted} ->
            {:public_key.pkix_decode_cert(der, :otp), der}
          end)

        {:ok, pins}
    end
  rescue
    _ -> {:error, :invalid_peer_cert_file}
  end

  defp verify_peer(cert, {:bad_cert, :selfsigned_peer}, state), do: verify_pin(cert, state)
  defp verify_peer(_, {:bad_cert, reason}, _), do: {:fail, reason}
  defp verify_peer(_, {:extension, _}, state), do: {:unknown, state}
  defp verify_peer(cert, :valid_peer, state), do: verify_pin(cert, state)
  defp verify_peer(_, :valid, state), do: {:valid, state}

  defp verify_pin(cert, %{pins: pins, reference_id: reference_id} = state) do
    # Compare the whole decoded certificate for OTP24 callback compatibility, then
    # validate its original DER rather than re-encoding the peer certificate.
    case Enum.find(pins, fn {identity, _der} -> identity == cert end) do
      {_, der} ->
        # OTP's selfsigned_peer shortcut skips leaf traversal. Traverse the pinned
        # certificate explicitly to check time, self-signature and extensions.
        case :public_key.pkix_path_validation(der, [der],
               verify_fun: {&verify_path/3, reference_id}
             ) do
          {:ok, _} -> {:valid, state}
          {:error, reason} -> {:fail, reason}
        end

      nil ->
        {:fail, :untrusted_peer_certificate}
    end
  end

  defp verify_path(_, {:bad_cert, reason}, _), do: {:fail, reason}

  defp verify_path(_, {:extension, {:Extension, {2, 5, 29, 37}, _, usages}}, state) do
    if {1, 3, 6, 1, 5, 5, 7, 3, 1} in usages,
      do: {:valid, state},
      else: {:fail, :invalid_ext_key_usage}
  end

  defp verify_path(_, {:extension, _}, state), do: {:unknown, state}
  defp verify_path(_, :valid, state), do: {:valid, state}

  defp verify_path(cert, :valid_peer, reference_id) do
    hostname_matches =
      :public_key.pkix_verify_hostname(cert, [reference_id],
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )

    cond do
      not hostname_matches -> {:fail, :hostname_check_failed}
      not signing_permitted?(cert) -> {:fail, :invalid_key_usage}
      true -> {:valid, reference_id}
    end
  end

  defp signing_permitted?(cert) do
    extensions = cert |> certificate(:tbsCertificate) |> tbs_certificate(:extensions)

    case extensions do
      :asn1_NOVALUE ->
        true

      extensions ->
        Enum.all?(extensions, fn
          {:Extension, {2, 5, 29, 15}, _, usages} -> :digitalSignature in usages
          _ -> true
        end)
    end
  end
end
