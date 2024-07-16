defmodule Astarte.AppEngine.API.Devices.Device do
  use Ash.Resource,
    domain: Astarte.AppEngine.API.Devices,
    data_layer: AshScyllaDB.DataLayer,
    extensions: [AshGraphql.Resource]

  alias Astarte.AppEngine.API.Devices.Device.Changes
  alias Astarte.AppEngine.API.Devices.Device.Calculations
  alias Astarte.AppEngine.API.Devices.Device.InterfaceInfo
  alias Astarte.AppEngine.API.Devices.Device.ManualActions

  graphql do
    type :device

    field_names group_names: :groups

    queries do
      get :device, :read
      list :devices, :read, relay?: true
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:destroy]

    create :create do
      accept [
        :first_registration,
        :inhibit_credentials_request,
        :first_credentials_request,
        :last_connection,
        :last_disconnection,
        :last_credentials_request_ip,
        :last_seen_ip,
        :connected,
        :total_received_msgs,
        :total_received_bytes,
        :attributes,
        :aliases,
        :groups,
        :introspection,
        :introspection_minor,
        :old_introspection,
        :exchanged_bytes_by_interface,
        :exchanged_msgs_by_interface,
        :credentials_secret,
        :cert_serial,
        :cert_aki,
        :pending_empty_cache
      ]

      # We require device_id as argument, and convert it to a UUID below
      argument :device_id, :string do
        allow_nil? false
      end

      change Changes.SetDeviceId
    end

    read :read do
      primary? true

      pagination do
        keyset? true
        required? false
      end
    end

    update :start_deletion do
      manual ManualActions.StartDeviceDeletion
    end
  end

  attributes do
    # In the struct the :id key will contain the device ID as a UUID
    # The UUID will be in the string representation since it's the path of least resistance
    # The :device_id key will contain the Device ID in the Astarte representation, see
    # the calculations sections
    uuid_primary_key :id do
      source :device_id
    end

    attribute :first_registration, :utc_datetime_usec do
      public? true
    end

    attribute :inhibit_credentials_request, :boolean do
      public? true
    end

    attribute :first_credentials_request, :utc_datetime_usec do
      public? true
    end

    attribute :last_connection, :utc_datetime_usec do
      public? true
    end

    attribute :last_disconnection, :utc_datetime_usec do
      public? true
    end

    attribute :connected, :boolean do
      public? true
      default false
    end

    attribute :total_received_msgs, :integer do
      public? true
      default 0
    end

    attribute :total_received_bytes, :integer do
      public? true
      default 0
    end

    attribute :last_credentials_request_ip, AshScyllaDB.Types.Inet do
      public? true
    end

    attribute :last_seen_ip, AshScyllaDB.Types.Inet do
      public? true
    end

    attribute :attributes, AshScyllaDB.Types.Map do
      public? true
      constraints key: :string, value: :string
      default %{}
    end

    attribute :aliases, AshScyllaDB.Types.Map do
      public? true
      constraints key: :string, value: :string
      default %{}
    end

    # These below are all private attributes. They are mostly decoupled from public
    # facing stuff via calculations

    attribute :groups, AshScyllaDB.Types.Map do
      constraints key: :string, value: Ecto.UUID
      default %{}
    end

    attribute :introspection, AshScyllaDB.Types.Map do
      constraints key: :string, value: :integer
      default %{}
    end

    attribute :introspection_minor, AshScyllaDB.Types.Map do
      constraints key: :string, value: :integer
      default %{}
    end

    attribute :old_introspection, AshScyllaDB.Types.Map do
      constraints key: Exandra.Tuple, types: [:string, :integer], value: :integer
      default %{}
    end

    attribute :exchanged_bytes_by_interface, AshScyllaDB.Types.Map do
      constraints key: Exandra.Tuple, types: [:string, :integer], value: :integer
      default %{}
    end

    attribute :exchanged_msgs_by_interface, AshScyllaDB.Types.Map do
      constraints key: Exandra.Tuple, types: [:string, :integer], value: :integer
      default %{}
    end

    attribute :credentials_secret, :string
    attribute :cert_serial, :string
    attribute :cert_aki, :string
    attribute :pending_empty_cache, :boolean
  end

  calculations do
    calculate :device_id, :string, Calculations.DeviceId do
      public? true
    end

    calculate :deletion_in_progress, :boolean, Calculations.DeletionInProgress do
      public? true
    end

    calculate :interfaces, {:array, InterfaceInfo}, Calculations.Interfaces do
      public? true
    end

    calculate :old_interfaces, {:array, InterfaceInfo}, Calculations.OldInterfaces do
      public? true
    end

    calculate :group_names, {:array, :string}, Calculations.GroupNames do
      public? true
    end
  end

  scylladb do
    repo Astarte.AppEngine.API.Repo
    table "devices"
    partition_key [:id]
  end
end
