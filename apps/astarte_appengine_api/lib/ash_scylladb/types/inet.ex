defmodule AshScyllaDB.Types.Inet do
  @moduledoc """
  A map type that uses Exandra.Inet underneath.
  """

  use Ash.Type
  use AshGraphql.Type

  @impl AshGraphql.Type
  def graphql_type(_), do: :string

  @impl Ash.Type
  def storage_type do
    Exandra.Inet.type()
  end

  @impl Ash.Type
  def cast_input(value, _constraints) do
    with {:ok, value} <- Exandra.Inet.cast(value) do
      {:ok, to_binary(value)}
    end
  end

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, _constraints) do
    with {:ok, value} <- Exandra.Inet.load(value) do
      {:ok, to_binary(value)}
    end
  end

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _constraints) do
    with {:ok, value} <- Exandra.Inet.cast(value) do
      Exandra.Inet.dump(value)
    end
  end

  defp to_binary(inet) do
    :inet.ntoa(inet)
  end
end
