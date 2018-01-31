defmodule Cluster.AppTest do
  @moduledoc false

  use ExUnit.Case

  import ExUnit.CaptureLog

  defmodule TestStrategy do
    @moduledoc false
    use Cluster.Strategy

    def start_link(opts) do
      opts
      |> Keyword.fetch!(:config)
      |> Keyword.fetch!(:caller)
      |> send({:opts, opts})

      {:ok, nil}
    end
  end

  describe "start/2" do
    test "calls strategy with right arguments" do
      restart_application(
        topologies: [
          test: [
            strategy: TestStrategy,
            config: [
              caller: self()
            ]
          ]
        ]
      )

      assert_receive {:opts, options}
      assert options[:topology] == :test
      assert {:net_kernel, :connect, []} = options[:connect]
      assert {:net_kernel, :disconnect, []} = options[:disconnect]
      assert {:erlang, :nodes, [:connected]} = options[:list_nodes]
      assert [caller: _] = options[:config]
      refute options[:block_startup]
    end

    test "sets block_startup" do
      restart_application(
        topologies: [
          test: [
            block_startup: true,
            strategy: TestStrategy,
            config: [
              caller: self()
            ]
          ]
        ]
      )

      assert_receive {:opts, options}
      assert options[:block_startup]
    end
  end

  defp restart_application(config) do
    capture_log(fn ->
      Application.stop(:libcluster)
    end)

    for {key, value} <- config do
      Application.put_env(:libcluster, key, value)
    end

    capture_log(fn ->
      Application.ensure_all_started(:libcluster)
    end)
  end
end
