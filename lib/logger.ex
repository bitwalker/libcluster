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

  def warn(t, msg) do
    case Application.get_env(:libcluster, :warn, true) do
      wrn when wrn in [true, :true, "true"] ->
        Logger.warn(log_message(t, msg))

      _ ->
        :ok
    end
  end

  def info(t, msg), do: Logger.info(log_message(t, msg))
  def error(t, msg), do: Logger.error(log_message(t, msg))

  @compile {:inline, log_message: 2}
  defp log_message(t, msg) do
    "[libcluster:#{t}] #{msg}"
  end
end
