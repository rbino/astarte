defmodule AshScyllaDB.Types.Map do
  @constraints [
    key: [
      type: :any,
      required: true,
      doc: "The type of the keys in the map."
    ],
    value: [
      type: :any,
      required: true,
      doc: "The type of the values in the map."
    ],
    field: [
      type: :atom,
      doc: false
    ],
    schema: [
      type: :atom,
      doc: false
    ],
    # These are needed due to how Exandra.Map works internally with parameterized types
    type: [
      type: :any
    ],
    types: [
      type: :any
    ]
  ]

  @moduledoc """
  A map type that uses Exandra.Map underneath.

  ### Constraints

  This type accepts as constraints the same options that can be passed to
  Exandra.Map
  """

  use Ash.Type
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :json

  @impl true
  def constraints, do: @constraints

  @impl true
  def init(constraints) do
    params = Exandra.Map.init(constraints)
    {:ok, Keyword.put(constraints, :params, params)}
  rescue
    err -> {:error, "Failed to init Exandra.Map: #{err}"}
  end

  @impl true
  def storage_type(constraints) do
    Exandra.Map.type(constraints[:params])
  end

  @impl true
  def cast_input(value, constraints) do
    Exandra.Map.cast(value, constraints[:params])
  end

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, constraints) do
    Exandra.Map.cast(value, constraints[:params])
  end

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, constraints) do
    dumper = &Ecto.Type.dump/2
    Exandra.Map.dump(value, dumper, constraints[:params])
  end
end
