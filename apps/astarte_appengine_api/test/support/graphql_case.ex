defmodule Astarte.AppEngine.APIWeb.GraphqlCase do
  use ExUnit.CaseTemplate

  alias Astarte.AppEngine.API.Devices.Device

  using do
    quote do
      import Astarte.AppEngine.APIWeb.GraphqlCase
    end
  end

  @port 9042

  setup_all do
    realm = generate_unique_realm()

    keyspace = realm

    opts = [keyspace: keyspace, nodes: ["localhost:#{@port}"], sync_connect: 1000]

    create_keyspace(keyspace)

    on_exit(fn ->
      drop_keyspace(keyspace)
    end)

    setup_keyspace(opts)

    %{start_opts: opts, realm: realm, keyspace: keyspace}
  end

  setup %{keyspace: keyspace} do
    truncate_all_tables(keyspace)
    :ok
  end

  def create_keyspace(keyspace) when is_binary(keyspace) do
    opts = [nodes: ["localhost:#{@port}"], keyspace: keyspace, sync_connect: 1000]
    assert Exandra.storage_up(opts) in [:ok, {:error, :already_up}]
  end

  def drop_keyspace(keyspace) when is_binary(keyspace) do
    opts = [nodes: ["localhost:#{@port}"], keyspace: keyspace, sync_connect: 1000]
    assert Exandra.storage_down(opts) in [:ok, {:error, :already_down}]
  end

  def truncate_all_tables(keyspace) do
    {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{@port}"], keyspace: keyspace)

    query = "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?"

    conn
    |> Xandra.execute!(query, [{"varchar", keyspace}])
    |> Enum.each(fn %{"table_name" => table} -> Xandra.execute!(conn, "TRUNCATE #{table}") end)

    Xandra.stop(conn)
  end

  def drop_all_tables(keyspace) do
    {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{@port}"], keyspace: keyspace)

    query = "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?"

    conn
    |> Xandra.execute!(query, [{"varchar", keyspace}])
    |> Enum.each(fn %{"table_name" => table} ->
      Xandra.execute!(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    Xandra.stop(conn)
  end

  defp generate_unique_realm do
    "realm#{System.unique_integer([:positive])}"
  end

  defp setup_keyspace(opts) do
    {:ok, conn} = Xandra.start_link(Keyword.drop(opts, [:sync_connect]))

    Xandra.execute!(conn, """
    CREATE TABLE kv_store (
      group varchar,
      key varchar,
      value blob,

      PRIMARY KEY ((group), key)
    );
    """)

    Xandra.execute!(conn, """
    CREATE TABLE names (
      object_name varchar,
      object_type int,
      object_uuid uuid,

      PRIMARY KEY ((object_name), object_type)
    );
    """)

    Xandra.execute!(conn, """
    CREATE TABLE grouped_devices (
      group_name varchar,
      insertion_uuid timeuuid,
      device_id uuid,
      PRIMARY KEY ((group_name), insertion_uuid, device_id)
    );

    """)

    Xandra.execute!(conn, """
    CREATE TABLE devices (
      device_id uuid,
      aliases map<ascii, varchar>,
      introspection map<ascii, int>,
      introspection_minor map<ascii, int>,
      old_introspection map<frozen<tuple<ascii, int>>, int>,
      protocol_revision int,
      first_registration timestamp,
      credentials_secret ascii,
      inhibit_credentials_request boolean,
      cert_serial ascii,
      cert_aki ascii,
      first_credentials_request timestamp,
      last_connection timestamp,
      last_disconnection timestamp,
      connected boolean,
      pending_empty_cache boolean,
      total_received_msgs bigint,
      total_received_bytes bigint,
      exchanged_msgs_by_interface map<frozen<tuple<ascii, int>>, bigint>,
      exchanged_bytes_by_interface map<frozen<tuple<ascii, int>>, bigint>,
      last_credentials_request_ip inet,
      last_seen_ip inet,
      groups map<text, timeuuid>,
      attributes map<varchar, varchar>,

      PRIMARY KEY (device_id)
    );
    """)

    Xandra.execute!(conn, """
    CREATE TABLE deletion_in_progress (
      device_id uuid,
      vmq_ack boolean,
      dup_start_ack boolean,
      dup_end_ack boolean,
      PRIMARY KEY (device_id)
    );
    """)

    :ok = Xandra.stop(conn)
  end

  def device_fixture(opts) do
    {tenant, opts} = Keyword.pop!(opts, :tenant)

    default_device_id =
      Astarte.Core.Device.random_device_id()
      |> Astarte.Core.Device.encode_device_id()

    params = Enum.into(opts, %{device_id: default_device_id})

    Device
    |> Ash.Changeset.for_create(:create, params, tenant: tenant)
    |> Ash.create!(load: :device_id)
  end
end
