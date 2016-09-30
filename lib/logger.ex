defmodule Cluster.Logger do
  @moduledoc false
  require Logger

  def debug(msg), do: log(:debug, msg)
  def info(msg),  do: log(:info, msg)
  def warn(msg),  do: log(:warn, msg)
  def error(msg), do: log(:error, msg)

  defp log(level, msg), do: apply(Logger, level, ["[libcluster] #{msg}"])
end
