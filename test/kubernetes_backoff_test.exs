defmodule Cluster.Strategy.Kubernetes.BackoffTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Cluster.Strategy.Kubernetes.Backoff

  describe "delay/2" do
    test "is disabled when the option is unset or false" do
      assert Backoff.delay(nil, 0) == 0
      assert Backoff.delay(false, 3) == 0
    end

    test "grows exponentially and stops at the configured cap" do
      opts = [base_ms: 100, max_ms: 1_000, jitter: 0]

      assert Backoff.delay(opts, 0) == 100
      assert Backoff.delay(opts, 1) == 200
      assert Backoff.delay(opts, 2) == 400
      assert Backoff.delay(opts, 3) == 800
      assert Backoff.delay(opts, 4) == 1_000
      assert Backoff.delay(opts, 10_000) == 1_000
    end

    test "stays within the jitter band below the exponential step" do
      opts = [base_ms: 1_000, max_ms: 1_000, jitter: 0.2]

      for delay <- for(_ <- 1..200, do: Backoff.delay(opts, 0)) do
        assert delay >= 800 and delay <= 1_000
      end
    end

    test "uses the defaults for true" do
      delay = Backoff.delay(true, 0)

      assert delay >= 40 and delay <= 50
    end
  end
end
