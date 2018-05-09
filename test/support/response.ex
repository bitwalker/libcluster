defmodule Cluster.Fixtures.RancherResponse do
  @moduledoc """
  Fixtures for JSON API responses from rancher metadata
  """

  def service_response(ip_addr) do
    container_struct(ip_addr) |> Jason.encode!()
  end

  def batch_response(ip_addrs) do
    ip_addrs |> Enum.map(&container_struct(&1)) |> Jason.encode!()
  end

  defp container_struct(ip_addr) do
    %{
      containers: [
        %{
          ips: [ip_addr],
          metadata_kind: "container",
          name: "front-api-api-1",
          primary_ip: ip_addr,
          service_index: "1",
          service_name: "api",
          stack_name: "front-api",
          start_count: 1,
          state: "running",
          system: false,
          uuid: "04ee2e72-6ad5-410e-a98b-28e1aecc45db"
        }
      ],
      metadata_kind: "service",
      name: "api",
      primary_service_name: "api",
      scale: 1,
      stack_name: "front-api",
      stack_uuid: "fb2671ed-375c-4bc4-84b2-94ac9b40e3f2",
      state: "active",
      uuid: "5633ac30-1c1a-481c-9540-7cf5e4a796e6"
    }
  end
end
