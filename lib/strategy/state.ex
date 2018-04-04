defmodule Cluster.Strategy.State do
  @moduledoc false

  @type t :: %__MODULE__{
          topology: atom,
          connect: {module, atom, [term]},
          disconnect: {module, atom, [term]},
          list_nodes: {module, atom, [:connected] | [:connected | [any]]},
          meta: term,
          config: [{atom, term}]
        }

  defstruct topology: nil,
            connect: nil,
            disconnect: nil,
            list_nodes: nil,
            meta: nil,
            config: []
end
