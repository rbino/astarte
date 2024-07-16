defmodule Astarte.AppEngine.API.Devices.Device.Calculations.OldInterfaces do
  use Ash.Resource.Calculation

  def load(_query, _opts, _context) do
    [
      :old_introspection,
      :exchanged_bytes_by_interface,
      :exchanged_msgs_by_interface
    ]
  end

  def calculate(records, _opts, _context) do
    interface_info_lists =
      records
      |> Enum.map(fn record ->
        record.old_introspection
        |> Enum.map(fn {{interface_name, major}, minor} ->
          exchanged_key = {interface_name, major}

          %{
            name: interface_name,
            major: major,
            minor: minor,
            exchanged_msgs: Map.get(record.exchanged_msgs_by_interface, exchanged_key, 0),
            exchanged_bytes: Map.get(record.exchanged_bytes_by_interface, exchanged_key, 0)
          }
        end)
      end)

    {:ok, interface_info_lists}
  end
end
