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

defmodule Astarte.Import.PopulateDB.Queries do
  alias Astarte.Core.Mapping
  require Logger

  def update_device_introspection({conn, realm}, device_id, introspection, introspection_minor) do
    introspection_update_statement = """
    UPDATE #{realm}.devices
    SET introspection=?, introspection_minor=?
    WHERE device_id=?
    """

    params = [
      {"map<ascii, int>", introspection},
      {"map<ascii, int>", introspection_minor},
      {"uuid", device_id}
    ]

    with {:ok, %Xandra.Void{}} <-
           Xandra.execute(conn, introspection_update_statement, params, consistency: :quorum) do
      :ok
    end
  end

  def add_old_interfaces({conn, realm}, device_id, old_interfaces) do
    old_introspection_update_statement = """
    UPDATE #{realm}.devices
    SET old_introspection = old_introspection + :introspection
    WHERE device_id=:device_id
    """

    params = [
      {"map<frozen<tuple<ascii, int>>, int>", old_interfaces},
      {"uuid", device_id}
    ]

    with {:ok, %Xandra.Void{}} <-
           Xandra.execute(conn, old_introspection_update_statement, params, consistency: :quorum) do
      :ok
    end
  end

  def do_register_device({conn, realm}, device_id, credentials_secret, registration_timestamp) do
    statement = """
    INSERT INTO #{realm}.devices
    (
      device_id, first_registration, credentials_secret, inhibit_credentials_request,
      protocol_revision, total_received_bytes, total_received_msgs
    ) VALUES (?, ?, ?, false, 0, 0, 0)
    """

    params = [
      {"uuid", device_id},
      {"timestamp", registration_timestamp},
      {"ascii", credentials_secret}
    ]

    with {:ok, _} <- Xandra.execute(conn, statement, params, consistency: :quorum) do
      :ok
    else
      {:error, %Xandra.Error{message: message}} ->
        Logger.warn("DB error: #{message}")

      {:error, %Xandra.ConnectionError{}} ->
        Logger.info("DB connection error.")
    end
  end

  def update_device_after_credentials_request(
        {conn, realm},
        device_id,
        %{serial: serial, aki: aki} = _cert_data,
        device_ip,
        first_credentials_request_timestamp
      ) do
    statement = """
    UPDATE #{realm}.devices
    SET cert_aki=?, cert_serial=?, last_credentials_request_ip=?,
    first_credentials_request=?
    WHERE device_id=?
    """

    params = [
      {"ascii", aki},
      {"ascii", serial},
      {"inet", device_ip},
      {"timestamp", first_credentials_request_timestamp},
      {"uuid", device_id}
    ]

    with {:ok, _} <- Xandra.execute(conn, statement, params, consistency: :quorum) do
      :ok
    else
      {:error, %Xandra.Error{message: message}} ->
        Logger.warn("DB error: #{message}")

      {:error, %Xandra.ConnectionError{}} ->
        Logger.info("DB connection error.")
    end
  end

  def set_pending_empty_cache({conn, realm}, device_id, pending_empty_cache) do
    pending_empty_cache_statement = """
    UPDATE #{realm}.devices
    SET pending_empty_cache = ?
    WHERE device_id = ?
    """

    params = [
      {"boolean", pending_empty_cache},
      {"uuid", device_id}
    ]

    with {:ok, _result} <- Xandra.execute(conn, pending_empty_cache_statement, params) do
      :ok
    else
      {:error, %Xandra.Error{message: message}} ->
        Logger.warn("set_pending_empty_cache: database error: #{message}")
        {:error, :database_error}

      {:error, %Xandra.ConnectionError{reason: reason}} ->
        Logger.warn("set_pending_empty_cache: connection error: #{inspect(reason)}")
        {:error, :database_error}
    end
  end

  def set_device_connected({conn, realm}, device_id, tstamp, ip_address) do
    device_update_statement = """
    UPDATE #{realm}.devices
    SET connected=true, last_connection=?, last_seen_ip=?
    WHERE device_id=?
    """

    params = [
      {"timestamp", tstamp},
      {"inet", ip_address},
      {"uuid", device_id}
    ]

    with {:ok, _} <- Xandra.execute(conn, device_update_statement, params, consistency: :quorum) do
      :ok
    end
  end

  def set_device_disconnected({conn, realm}, device_id, tstamp, tot_recv_msgs, tot_recv_bytes) do
    device_update_statement = """
    UPDATE #{realm}.devices
    SET connected=false,
        last_disconnection=?,
        total_received_msgs=?,
        total_received_bytes=?
    WHERE device_id=?
    """

    params = [
      {"timestamp", tstamp},
      {"bigint", tot_recv_msgs},
      {"bigint", tot_recv_bytes},
      {"uuid", device_id}
    ]

    with {:ok, _} <-
           Xandra.execute(conn, device_update_statement, params, consistency: :local_quorum) do
      :ok
    end
  end

  def insert_path(
        {conn, realm},
        device_id,
        interface_descriptor,
        endpoint,
        path,
        value_timestamp,
        reception_timestamp,
        _opts
      ) do
    # TODO: do not hardcode individual_properties here
    # TODO: handle TTL
    insert_statement = """
    INSERT INTO #{realm}.individual_properties
        (device_id, interface_id, endpoint_id, path,
        reception_timestamp, reception_timestamp_submillis, datetime_value)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """

    params = [
      {"uuid", device_id},
      {"uuid", interface_descriptor.interface_id},
      {"uuid", endpoint.endpoint_id},
      {"varchar", path},
      {"timestamp", reception_timestamp},
      {"smallint", rem(DateTime.to_unix(reception_timestamp, :microsecond), 100)},
      {"timestamp", value_timestamp}
    ]

    with {:ok, _} <-
           Xandra.execute(conn, insert_statement, params,
             consitency: path_consistency(interface_descriptor, endpoint)
           ) do
      :ok
    else
      {:error, %Xandra.Error{message: message}} ->
        Logger.warn("insert_path: database error: #{message}")
        {:error, :database_error}

      {:error, %Xandra.ConnectionError{reason: reason}} ->
        Logger.warn("insert_path: connection error: #{inspect(reason)}")
        {:error, :database_error}
    end
  end

  defp path_consistency(_interface_descriptor, %Mapping{reliability: :unreliable} = _mapping) do
    :one
  end

  defp path_consistency(_interface_descriptor, _mapping) do
    :local_quorum
  end
end
