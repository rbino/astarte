defmodule Astarte.AppEngine.API.Devices.DeletionInProgress do
  use Ash.Resource,
    domain: Astarte.AppEngine.API.Devices,
    data_layer: AshScyllaDB.DataLayer

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :device_id,
        :vmq_ack,
        :dup_start_ack,
        :dup_end_ack
      ]

      primary? true
    end

    update :update do
      accept [
        :vmq_ack,
        :dup_start_ack,
        :dup_end_ack
      ]

      primary? true
    end
  end

  attributes do
    attribute :device_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :vmq_ack, :boolean, default: false
    attribute :dup_start_ack, :boolean, default: false
    attribute :dup_end_ack, :boolean, default: false
  end

  scylladb do
    repo Astarte.AppEngine.API.Repo
    table "deletion_in_progress"
    partition_key [:device_id]
  end
end
