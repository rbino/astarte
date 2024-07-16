defmodule Astarte.AppEngine.API.Devices.Device.Calculations.DeletionInProgress do
  use Ash.Resource.Calculation

  require Ash.Query

  alias Astarte.AppEngine.API.Devices.DeletionInProgress

  def calculate(records, _opts, context) do
    %{tenant: tenant} = context

    device_ids = Enum.map(records, & &1.id)

    # TODO: filtering id with an array in query is not supported by Exandra
    # We could verify if that can be fixed

    # deletions_in_progress =
    #   DeletionInProgress
    #   |> Ash.Query.filter(device_id in ^device_ids)
    #   |> Ash.read!(tenant: tenant)

    deletions_in_progress =
      Enum.flat_map(records, fn record ->
        device_id = record.id

        DeletionInProgress
        |> Ash.Query.filter(device_id == ^device_id)
        |> Ash.read!(tenant: tenant)
      end)

    deletion_in_progress_by_device_id =
      Map.new(device_ids, fn device_id ->
        deletion_in_progress? = Enum.any?(deletions_in_progress, &(&1.device_id == device_id))

        {device_id, deletion_in_progress?}
      end)

    {:ok, deletion_in_progress_by_device_id}
  end
end
