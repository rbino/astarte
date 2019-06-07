#
# This file is part of Astarte.
#
# Copyright 2019 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.Import.PopulateDB do
  alias Astarte.Core.CQLUtils
  alias Astarte.Core.Device
  alias Astarte.Core.InterfaceDescriptor
  alias Astarte.Core.Mapping
  alias Astarte.Core.Mapping.EndpointsAutomaton
  alias Astarte.DataAccess.Database
  alias Astarte.DataAccess.Interface
  alias Astarte.DataAccess.Mappings
  alias Astarte.Import
  alias Astarte.Import.PopulateDB.Queries
  require Logger

  defmodule State do
    defstruct [
      :prepared_params,
      :interface_descriptor,
      :mapping,
      :mappings,
      :last_seen_reception_timestamp,
      :prepared_query,
      :value_type
    ]
  end

  def populate(realm, xml) do
    {:ok, conn} = Database.connect(realm)
    nodes = Application.get_env(:cqerl, :cassandra_nodes)
    {host, port} = Enum.random(nodes)
    {:ok, xandra_conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])

    got_interface_fun = fn %Import.State{data: data} = state, interface_name, major, _minor ->
      {:ok, interface_desc} = Interface.fetch_interface_descriptor(conn, interface_name, major)
      {:ok, mappings} = Mappings.fetch_interface_mappings(conn, interface_desc.interface_id)

      %Import.State{
        state
        | data: %State{data | interface_descriptor: interface_desc, mappings: mappings}
      }
    end

    got_path_fun = fn %Import.State{data: data} = state, path ->
      %Import.State{
        device_id: device_id,
        data: %State{
          mappings: mappings,
          interface_descriptor: %InterfaceDescriptor{
            interface_id: interface_id,
            automaton: automaton,
            storage: storage
          }
        }
      } = state

      {:ok, endpoint_id} = EndpointsAutomaton.resolve_path(path, automaton)

      mapping = Enum.find(mappings, fn mapping -> mapping.endpoint_id == endpoint_id end)
      %Mapping{value_type: value_type} = mapping

      db_column_name = CQLUtils.type_to_db_column_name(value_type)

      statement = """
      INSERT INTO #{realm}.#{storage}
      (
        value_timestamp, reception_timestamp, reception_timestamp_submillis, #{db_column_name},
        device_id, interface_id, endpoint_id, path
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """

      {:ok, prepared_query} = Xandra.prepare(xandra_conn, statement)

      {:ok, decoded_device_id} = Device.decode_device_id(device_id)

      prepared_params = [
        decoded_device_id,
        interface_id,
        endpoint_id,
        path
      ]

      %Import.State{
        state
        | data: %State{
            data
            | mapping: mapping,
              prepared_params: prepared_params,
              prepared_query: prepared_query,
              value_type: value_type
          }
      }
    end

    got_path_end_fun = fn state ->
      %Import.State{
        device_id: device_id,
        path: path,
        data: %State{
          interface_descriptor: interface_descriptor,
          mapping: mapping,
          last_seen_reception_timestamp: reception_timestamp
        }
      } = state

      dbclient = {xandra_conn, realm}

      {:ok, decoded_device_id} = Device.decode_device_id(device_id)

      Queries.insert_path(
        dbclient,
        decoded_device_id,
        interface_descriptor,
        mapping,
        path,
        reception_timestamp,
        reception_timestamp,
        []
      )

      state
    end

    got_device_end = fn state ->
      %Import.State{
        device_id: device_id,
        introspection: introspection,
        old_introspection: old_introspection,
        first_registration: first_registration,
        credentials_secret: credentials_secret,
        cert_serial: cert_serial,
        cert_aki: cert_aki,
        first_credentials_request: first_credentials_request,
        last_connection: last_connection,
        last_disconnection: last_disconnection,
        pending_empty_cache: pending_empty_cache,
        total_received_msgs: total_received_msgs,
        total_received_bytes: total_received_bytes,
        last_credentials_request_ip: last_credentials_request_ip,
        last_seen_ip: last_seen_ip
      } = state

      {:ok, decoded_device_id} = Device.decode_device_id(device_id)

      {introspection_major, introspection_minor} =
        Enum.reduce(introspection, {%{}, %{}}, fn item, acc ->
          {interface, {major, minor}} = item
          {introspection_major, introspection_minor} = acc

          {Map.put(introspection_major, interface, major),
           Map.put(introspection_minor, interface, minor)}
        end)

      dbclient = {xandra_conn, realm}

      Queries.do_register_device(
        dbclient,
        decoded_device_id,
        credentials_secret,
        first_registration
      )

      Queries.update_device_after_credentials_request(
        dbclient,
        decoded_device_id,
        %{serial: cert_serial, aki: cert_aki},
        last_credentials_request_ip,
        first_credentials_request
      )

      Queries.update_device_introspection(
        dbclient,
        decoded_device_id,
        introspection_major,
        introspection_minor
      )

      Queries.add_old_interfaces(dbclient, decoded_device_id, old_introspection)

      Queries.set_device_connected(dbclient, decoded_device_id, last_connection, last_seen_ip)

      Queries.set_device_disconnected(
        dbclient,
        decoded_device_id,
        last_disconnection,
        total_received_msgs,
        total_received_bytes
      )

      Queries.set_pending_empty_cache(dbclient, decoded_device_id, pending_empty_cache)

      state
    end

    fun = fn state, chars ->
      %Import.State{
        reception_timestamp: reception_timestamp,
        data: data
      } = state

      %State{
        prepared_params: prepared_params,
        prepared_query: prepared_query,
        value_type: value_type
      } = data

      reception_submillis = rem(DateTime.to_unix(reception_timestamp, :microsecond), 100)
      native_value = to_native_type(chars, value_type)

      params = [
        reception_timestamp,
        reception_timestamp,
        reception_submillis,
        native_value | prepared_params
      ]

      {:ok, %Xandra.Void{}} = Xandra.execute(xandra_conn, prepared_query, params)

      %Import.State{
        state
        | data: %State{data | last_seen_reception_timestamp: reception_timestamp}
      }
    end

    Import.parse(xml,
      data: %State{},
      got_data_fun: fun,
      got_device_end_fun: got_device_end,
      got_interface_fun: got_interface_fun,
      got_path_fun: got_path_fun,
      got_path_end_fun: got_path_end_fun
    )
  end

  defp to_native_type(value_chars, :double) do
    with float_string = to_string(value_chars),
         {value, ""} <- Float.parse(float_string) do
      value
    end
  end
end
