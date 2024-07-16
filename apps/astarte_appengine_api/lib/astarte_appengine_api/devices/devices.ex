defmodule Astarte.AppEngine.API.Devices do
  use Ash.Domain,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize? false
  end

  resources do
    resource Astarte.AppEngine.API.Devices.Device do
      define :start_device_deletion, action: :start_deletion
    end

    resource Astarte.AppEngine.API.Devices.DeletionInProgress
  end
end
