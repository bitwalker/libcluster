defmodule Cluster.Telemetry do
  @moduledoc false

  def setup_telemetry(event) do
    telemetry_handle_id = "test-telemetry-handler-#{inspect(self())}"

    :ok =
      :telemetry.attach_many(
        telemetry_handle_id,
        [
          event
        ],
        &send_to_pid/4,
        nil
      )

    :ok = ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(telemetry_handle_id) end)
  end

  defp send_to_pid(event, measurements, metadata, config) do
    pid = config[:pid] || self()

    send(pid, {:telemetry_event, {event, measurements, metadata, config}})
  end
end
