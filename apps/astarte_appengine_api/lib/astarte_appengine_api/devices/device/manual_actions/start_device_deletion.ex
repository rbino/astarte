defmodule Astarte.AppEngine.API.Devices.Device.ManualActions.StartDeviceDeletion do
  use Ash.Resource.ManualUpdate

  alias Astarte.AppEngine.API.Devices.DeletionInProgress

  def update(changeset, _opts, context) do
    tenant = context.tenant
    device = changeset.data

    Ash.create!(DeletionInProgress, %{device_id: device.id}, tenant: tenant)

    # TODO: implement deletion logic

    {:ok, device}
  end
end
