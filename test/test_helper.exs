defmodule Cluster.Nodes do
  @moduledoc false

  def connect(caller, result \\ true, node) do
    send(caller, {:connect, node})
    result
  end

  def disconnect(caller, result \\ true, node) do
    send(caller, {:disconnect, node})
    result
  end

  def list_nodes(nodes) do
    nodes
  end
end

# TODO: The following module should be a PR instead...
defmodule ExVCR.Adapter.Httpc.Converter do
  @moduledoc """
  Provides helpers to mock :httpc methods.
  """

  use ExVCR.Converter

  defp string_to_response(string) do
    response = Enum.map(string, fn {x, y} -> {String.to_atom(x), y} end)
    response = struct(ExVCR.Response, response)

    response =
      if response.status_code do
        status_code =
          response.status_code
          |> Enum.map(&convert_string_to_charlist/1)
          |> List.to_tuple()

        %{response | status_code: status_code}
      else
        response
      end

    response =
      if response.type == "error" do
        %{response | body: {String.to_atom(response.body), []}}
      else
        response
      end

    response =
      if is_map(response.headers) do
        headers =
          response.headers
          |> Map.to_list()
          |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        %{response | headers: headers}
      else
        response
      end

    response
  end

  defp convert_string_to_charlist(elem) do
    if is_binary(elem) do
      to_charlist(elem)
    else
      elem
    end
  end

  defp request_to_string([url]) do
    request_to_string([:get, {url, [], [], []}, [], []])
  end

  defp request_to_string([method, {url, headers}, http_options, options]) do
    request_to_string([method, {url, headers, [], []}, http_options, options])
  end

  # TODO: need to handle content_type
  defp request_to_string([method, {url, headers, _content_type, body}, http_options, options]) do
    %ExVCR.Request{
      url: parse_url(url),
      headers: parse_headers(headers),
      method: to_string(method),
      body: parse_request_body(body),
      options: [
        httpc_options: parse_keyword_list(options),
        http_options: parse_keyword_list(http_options)
      ]
    }
  end

  def parse_keyword_list(params) do
    Enum.map(params, fn {k, v} -> {k, inspect(v)} end)
  end

  defp response_to_string({:ok, {{http_version, status_code, reason_phrase}, headers, body}}) do
    %ExVCR.Response{
      type: "ok",
      status_code: [to_string(http_version), status_code, to_string(reason_phrase)],
      headers: parse_headers(headers),
      body: to_string(body)
    }
  end

  defp response_to_string({:error, {reason, _detail}}) do
    %ExVCR.Response{
      type: "error",
      body: Atom.to_string(reason)
    }
  end
end

ExUnit.start()
