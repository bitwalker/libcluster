defmodule Cluster.Logger do
  @moduledoc false
  require Logger


  def debug(t, msg, verbosity_level \\ 1)
  def debug(t, msg, verbose: verbosity_level), do: debug(t, msg, verbosity_level)
  def debug(t, msg, verbosity_level) do
    case Application.get_env(:libcluster, :debug, false) do
      dbg when dbg in [nil, false, "false"] ->
        :ok

      verbose when is_integer(verbose) and verbose < verbosity_level ->
        :ok

      _ ->
        Logger.debug(log_message(t, msg))
    end
  end

  def info(t, msg), do: Logger.info(log_message(t, msg))
  def warn(t, msg), do: Logger.warn(log_message(t, msg))
  def error(t, msg), do: Logger.error(log_message(t, msg))

  @doc """
  Hybrid between `Kernel.inspect/2` and `debug/2`.

  Similarly to `IO.inspect`, it makes possible to `spy` on a value,
  while returning it unchanged.

  Please note that the second argument is send as first argument to `debug/2`
  while the first argument is printed to the log handler via `Kernel.inspect/2`.
  This function also accepts a `:label` option (similarly to `IO.inspect/2`),
  and a `:verbose` option (by default: `verbose = 1`, the message is suppressed
  when `verbose < Application.get_env(:libcluster, :debug)`), but all the other
  options are forwarded to `Kernel.inspect/2`.
  """
  def debug_inspect(value, t, opts \\ []) do
    {label, opts} = Keyword.pop(opts, :label, nil)
    {verbose, opts} = Keyword.pop(opts, :verbose, 1)
    label = if label, do: "#{label}: ", else: ""
    debug(t, "#{label}#{inspect(value, opts)}", verbose: verbose)
    value
  end

  @compile {:inline, log_message: 2}
  defp log_message(t, msg) do
    "[libcluster:#{t}] #{msg}"
  end
end
