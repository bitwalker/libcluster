defmodule Cluster.Strategy.Kubernetes.Backoff do
  @moduledoc false

  # The extra delay applied after a failed poll. Keeping the calculation here
  # makes the growth curve testable without sleeping in the strategy tests.
  @default_base_ms 50
  @default_max_ms 60_000
  @default_jitter 0.2

  # Cap the exponent so a long outage cannot build an enormous integer before
  # the result is clamped by :max_ms.
  @max_shift 20

  @doc """
  Returns the extra delay, in milliseconds, to apply after a failed poll.

  `setting` is the value of the `:kubernetes_poll_backoff` option: `nil` or
  `false` disables the backoff, `true` uses the defaults, and a keyword list
  overrides `:base_ms`, `:max_ms` and `:jitter`.
  """
  @spec delay(nil | boolean | keyword(), non_neg_integer()) :: non_neg_integer()
  def delay(nil, _attempt), do: 0
  def delay(false, _attempt), do: 0
  def delay(true, attempt), do: delay([], attempt)

  def delay(opts, attempt) when is_list(opts) do
    base_ms = Keyword.get(opts, :base_ms, @default_base_ms)
    max_ms = Keyword.get(opts, :max_ms, @default_max_ms)
    jitter = Keyword.get(opts, :jitter, @default_jitter)

    max_sleep = min(max_ms, base_ms * Bitwise.bsl(1, min(attempt, @max_shift)))

    # Stay in the order of magnitude of the exponential step while spreading
    # retries across clients, so recovering servers are not hit in lockstep.
    delay = trunc(max_sleep * (1 - jitter * :rand.uniform()))

    max(delay, 0)
  end
end
