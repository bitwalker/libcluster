defmodule Cluster.Logger do
  @moduledoc false
  require Logger

  def debug(t, msg), do: log(:debug, t, msg)
  def info(t, msg),  do: log(:info, t, msg)
  def warn(t, msg),  do: log(:warn, t, msg)
  def error(t, msg), do: log(:error, t, msg)

  defp log(t, level, msg), do: Logger.log(level, "[libcluster:#{t}] #{msg}")
end
