defmodule Cluster.Strategy.Kubernetes.EndpointSlice do
  @moduledoc false

  def list(url, headers, http_options, params, namespace) do
    request = {url, headers, http_options}

    with {:ok, slices} <- list_pages(request, Keyword.put(params, :limit, 500), [], MapSet.new()) do
      normalize(slices, namespace)
    end
  end

  defp list_pages(request, params, pages, seen) do
    with {:ok, items, continuation} <- request_page(request, params) do
      pages = [items | pages]

      cond do
        continuation == "" ->
          {:ok, pages |> Enum.reverse() |> Enum.flat_map(& &1)}

        MapSet.member?(seen, continuation) ->
          {:error, :repeated_continuation}

        true ->
          next_params =
            params
            |> Keyword.delete(:resourceVersion)
            |> Keyword.put(:continue, continuation)

          list_pages(request, next_params, pages, MapSet.put(seen, continuation))
      end
    end
  end

  defp request_page({url, headers, http_options}, params) do
    query = URI.encode_query(params, :rfc3986)

    case :httpc.request(:get, {~c"#{url}?#{query}", headers}, http_options, []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        decode_page(body)

      {:ok, {{_version, code, _status}, _headers, _body}} ->
        {:error, {:http_status, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_page(body) do
    with {:ok, %{"items" => items} = page} <- Jason.decode(body),
         true <- is_list(items),
         metadata when is_map(metadata) <- Map.get(page, "metadata", %{}),
         continuation when is_binary(continuation) or is_nil(continuation) <- metadata["continue"] do
      {:ok, items, continuation || ""}
    else
      _ -> {:error, :invalid_endpoint_slice_list}
    end
  end

  defp normalize(slices, namespace) do
    Enum.reduce_while(slices, {:ok, []}, fn slice, {:ok, groups} ->
      case normalize_slice(slice, namespace) do
        {:ok, nodes} -> {:cont, {:ok, [nodes | groups]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.flat_map(& &1)}
      error -> error
    end
  end

  defp normalize_slice(%{"addressType" => family} = slice, namespace)
       when family in ["IPv4", "IPv6"] do
    with endpoints when is_list(endpoints) or is_nil(endpoints) <- slice["endpoints"],
         metadata when is_map(metadata) <- Map.get(slice, "metadata", %{}),
         namespace when is_binary(namespace) and namespace != "" <-
           metadata["namespace"] || namespace,
         true <- Enum.all?(endpoints || [], &valid_endpoint?/1) do
      nodes =
        Enum.flat_map(endpoints || [], fn endpoint ->
          conditions = endpoint["conditions"] || %{}

          if conditions["ready"] == false or conditions["terminating"] == true do
            []
          else
            endpoint["addresses"]
            |> Enum.filter(&valid_address?(&1, family))
            |> Enum.map(fn address ->
              %{ip: address, namespace: namespace, hostname: endpoint["hostname"]}
            end)
          end
        end)

      {:ok, nodes}
    else
      _ -> {:error, :invalid_endpoint_slice}
    end
  end

  defp normalize_slice(%{"addressType" => family}, _namespace)
       when is_binary(family) and family not in ["IPv4", "IPv6"],
       do: {:ok, []}

  defp normalize_slice(_, _namespace), do: {:error, :invalid_endpoint_slice}

  defp valid_endpoint?(%{"addresses" => addresses} = endpoint) when is_list(addresses) do
    case endpoint["conditions"] do
      nil ->
        true

      conditions when is_map(conditions) ->
        Enum.all?(["ready", "terminating"], fn key ->
          conditions[key] in [nil, true, false]
        end)

      _ ->
        false
    end
  end

  defp valid_endpoint?(_), do: false

  defp valid_address?(address, family) when is_binary(address) do
    case {family, :inet.parse_address(String.to_charlist(address))} do
      {"IPv4", {:ok, {_, _, _, _}}} -> true
      {"IPv6", {:ok, {_, _, _, _, _, _, _, _}}} -> true
      _ -> false
    end
  end

  defp valid_address?(_, _), do: false
end
