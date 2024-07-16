defmodule Astarte.AppEngine.API.Devices.Device.InterfaceInfo do
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        name: [
          type: :string,
          allow_nil?: false
        ],
        major: [
          type: :integer,
          allow_nil?: false,
          constraints: [
            min: 0
          ]
        ],
        minor: [
          type: :integer,
          allow_nil?: false,
          constraints: [
            min: 0
          ]
        ],
        exchanged_msgs: [
          type: :integer,
          constraints: [
            min: 0
          ]
        ],
        exchanged_bytes: [
          type: :integer,
          constraints: [
            min: 0
          ]
        ]
      ]
    ]

  use AshGraphql.Type

  @impl AshGraphql.Type
  def graphql_type(_), do: :interface_info
end
