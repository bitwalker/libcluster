defmodule Cluster.Strategy.State do
  @moduledoc false

  @type t :: %__MODULE__{
    topology: atom(),
    connect: {module(), atom(), [term()]},
    disconnect: {module(), atom(), [term()]},
    meta: term(),
    config: [{atom(), term()}]
  }
  defstruct topology: nil,
            connect: nil,
            disconnect: nil,
            meta: nil,
            config: []
end
