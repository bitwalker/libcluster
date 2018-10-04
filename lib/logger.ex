defmodule Cluster.Logger do
  @moduledoc false
  require Logger

  def debug(t, msg) do
    case Application.get_env(:libcluster, :debug, false) do
      dbg when dbg in [nil, false, "false"] ->
        :ok

      _ ->
        Logger.debug(log_message(t, msg))
    end
  end

  def info(t, msg), do: Logger.info(log_message(t, msg))
  def warn(t, msg), do: Logger.warn(log_message(t, msg))
  def error(t, msg), do: Logger.error(log_message(t, msg))

  @compile {:inline, log_message: 2}
  defp log_message(t, msg) do
    "[libcluster:#{t}] #{msg}"
  end
end
