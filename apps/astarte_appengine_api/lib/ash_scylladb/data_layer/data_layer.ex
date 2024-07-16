defmodule AshScyllaDB.DataLayer do
  import Ecto.Query, only: [from: 2]

  require Ash.Expr

  # This, up to and including `use Spark.Dsl.Extension`, is what makes it possible
  # to use the `scylladb` section in an Ash resource. Check out existing extensions
  # and the Spark documentation to have more info, but basically you define sections
  # of the DSL using nested Elixir structs containing all the configuration
  @scylladb %Spark.Dsl.Section{
    name: :scylladb,
    describe: """
    Cassandra data layer configuration
    """,
    examples: [
      """
      scylladb do
        repo MyApp.Repo
        table "devices"
      end
      """
    ],
    schema: [
      repo: [
        type: :atom,
        required: true,
        doc: "The repo that will be used to fetch your data."
      ],
      table: [
        type: :string,
        required: true,
        doc: """
        The table to store and read the resource from.
        """
      ],
      partition_key: [
        type: {:list, :atom},
        required: true,
        doc: """
        The attributes used as partition key. Must have at least one item.
        """
      ],
      clustering_key: [
        type: {:list, :atom},
        default: [],
        doc: """
        The attributes used as clustering key, if any.
        """
      ]
    ]
  }

  @sections [@scylladb]

  # Verifiers, as the name implies, are used to verify some properties of the DSL.
  # There are also transformers (we don't have any here) which are able to transform
  # the DSL.
  @verifiers [
    AshScyllaDB.DataLayer.Verifiers.VerifyPartitionAndClusteringKeys
  ]

  use Spark.Dsl.Extension,
    sections: @sections,
    verifiers: @verifiers

  @moduledoc """
  A ScyllaDB data layer that leverages Ecto's Scylla capabilities.
  """

  @behaviour Ash.DataLayer

  require Logger

  # Most of the stuff here is inspired and/or outright copy-pasted from AshPostgres or AshSqlite
  # AshSql ideally should exist to factor out common functionality, and indeed it does, but there's
  # still some boilerplate needed to handle the differences in Ecto-backed databases.

  # can? is the callback that Ash calls to introspect the capabilities of the data layer
  @impl true
  # These are things we _can_ do
  def can?(_, :read), do: true
  def can?(_, :create), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :multitenancy), do: true
  def can?(_, :select), do: true
  def can?(_, :limit), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :filter), do: true
  def can?(_, :distinct), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, {:filter_expr, _}), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, {:atomic, :upsert}), do: true
  def can?(_, :async_engine), do: true
  def can?(_, :timeout), do: true
  def can?(_, :aggregate_filter), do: true

  # We declare we can sort to support pagination but we're dropping it for now,
  # see sort callback
  def can?(_, :sort), do: true
  def can?(_, {:sort, _}), do: true

  # These are things we _can't_ do
  # No distinct sort in ScyllaDB
  def can?(_, :distinct_sort), do: false
  # Scylla doesn't have transactions
  def can?(_, :transact), do: false
  # Scylla doesn't support offset
  def can?(_, :offset), do: false
  # Scylla has limited support for fancy stuff calculated on the SQL side
  def can?(_, :expression_calculation), do: false

  # We print additional can? calls so we can manually analyze them as we go
  def can?(resource, op) do
    Logger.info("Requested: can?(#{inspect(resource)}, #{inspect(op)})")
    false
  end

  # This callback initializes a data layer query (not to be confused with an Ash Query)
  # given a resource. In this case, our data layer query will be an Ecto query, and we
  # just retrieve the table from the resource introspection and initialize an Ecto
  # query with it
  @impl true
  def resource_to_query(resource, _domain) do
    from(row in {AshScyllaDB.DataLayer.Info.table(resource) || "", resource}, [])
  end

  # The Ash context contains, duh, some contextual information. We just use AshSql to
  # handle it here.
  @impl true
  def set_context(resource, data_layer_query, context) do
    AshSql.Query.set_context(resource, data_layer_query, AshScyllaDB.SqlImplementation, context)
  end

  @impl true
  def limit(query, nil, _), do: {:ok, query}

  # We  just apply the limit, nothing fancy
  def limit(query, limit, _resource) do
    {:ok, from(row in query, limit: ^limit)}
  end

  # Same stuff, nothing fancy, just select the columns we're given
  @impl true
  def select(query, select, _resource) do
    {:ok,
     from(row in query,
       select: struct(row, ^Enum.uniq(select))
     )}
  end

  # Here we do a couple of adjustments that we are able to do given our introspection
  # on partition/clustering keys before applying the filter
  @impl true
  def filter(query, filter, resource) do
    with {:ok, filter} <- adjust_partition_key_filter(filter, resource),
         {:ok, query} <- AshSql.Filter.filter(query, filter, resource) do
      {:ok, populate_allow_filtering_conditions(query, filter, resource)}
    end
  end

  # This is the biggest adjustment. Citing the ScyllaDB documentation:
  #
  #   Not all relations are allowed in a query. For instance, non-equal relations (where
  #   IN is considered as an equal relation) on a partition key are not supported (see the
  #   use of the TOKEN method below to do non-equal queries on the partition key)
  #
  # So here we recursively traverse the filter (Ash filters are basically a tree of structs
  # representing predicates/functions) and if we encounter an inequality operator involving
  # the partition key we transform the lhs and rhs to token(lhs) and token(rhs)
  #
  # Note that this means that foo > 400 will become token(foo) > token(400), but this at
  # least lets us support pagination. In the future I guess we could also detect when
  # we're doing this to paginate vs when it's supposed to be an actual inequality, and
  # return an error in the second case
  #
  # Also note that this doesn't cover yet some possible filter expressions (e.g. functions)
  # but I think this will be enough to get started
  defp adjust_partition_key_filter(expression, resource) do
    case expression do
      %Ash.Filter{expression: expression} = filter ->
        with {:ok, expression} <- adjust_partition_key_filter(expression, resource) do
          {:ok, %{filter | expression: expression}}
        end

      %Ash.Query.Not{expression: expression} = not_expr ->
        with {:ok, expression} <- adjust_partition_key_filter(expression, resource) do
          {:ok, %{not_expr | expression: expression}}
        end

      %Ash.Query.BooleanExpression{left: left, right: right} = expression ->
        with {:ok, left} <- adjust_partition_key_filter(left, resource),
             {:ok, right} <- adjust_partition_key_filter(right, resource) do
          {:ok, %{expression | left: left, right: right}}
        end

      %{__operator__?: true} = op ->
        if involves_partition_key?(op, resource) and not supported_partition_key_operator?(op) do
          convert_to_token_op(op, resource)
        else
          {:ok, op}
        end
    end
  end

  defp convert_to_token_op(op, resource) do
    with {:ok, expr} <- token_expr(op) do
      context = %{resource: resource}
      # Before we replace our filter we have to hydrate it. Basically, expressions are actually
      # templates and hydration replaces the values in the template
      Ash.Filter.hydrate_refs(expr, context)
    end
  end

  # Here we take all the possible inequality operators and replace them with a fragment
  # wrapping the lhs and rhs in the token() function.
  # For != we just return an error since it doesn't make sense even with token.
  defp token_expr(op) do
    case op do
      %Ash.Query.Operator.GreaterThan{} ->
        {:ok, Ash.Expr.expr(fragment("token(?) > token(?)", ^op.left, ^op.right))}

      %Ash.Query.Operator.GreaterThanOrEqual{} ->
        {:ok, Ash.Expr.expr(fragment("token(?) >= token(?)", ^op.left, ^op.right))}

      %Ash.Query.Operator.LessThan{} ->
        {:ok, Ash.Expr.expr(fragment("token(?) < token(?)", ^op.left, ^op.right))}

      %Ash.Query.Operator.LessThanOrEqual{} ->
        {:ok, Ash.Expr.expr(fragment("token(?) <= token(?)", ^op.left, ^op.right))}

      %Ash.Query.Operator.NotEq{} ->
        {:error, "cannot use != in an expression involving a partition key"}
    end
  end

  # If the lhs or the rhs is an attribute, we check if it's included in the partition key
  defp involves_partition_key?(%{left: %{attribute: %{name: name}}}, resource) do
    name in AshScyllaDB.DataLayer.Info.partition_key(resource)
  end

  defp involves_partition_key?(%{right: %{attribute: %{name: name}}}, resource) do
    name in AshScyllaDB.DataLayer.Info.partition_key(resource)
  end

  # Eveything else is skipped
  defp involves_partition_key?(_predicate, _resource), do: false

  # In and Eq are the only two supported predicates on the partition key
  defp supported_partition_key_operator?(%operator{}) do
    operator in [Ash.Query.Operator.In, Ash.Query.Operator.Eq, Ash.Query.Operator.IsNil]
  end

  # Another traversal of the filter. Here we save in the private context (__ash_bindings__)
  # some conditions that could require ALLOW FILTERING to be set on the query later.
  # Currently we just check if we have a filter on a non-primary key attribute.
  defp populate_allow_filtering_conditions(query, expression, resource) do
    case expression do
      %Ash.Filter{expression: expression} ->
        populate_allow_filtering_conditions(query, expression, resource)

      %Ash.Query.Not{expression: expression} ->
        populate_allow_filtering_conditions(query, expression, resource)

      %Ash.Query.BooleanExpression{left: left, right: right} ->
        query
        |> populate_allow_filtering_conditions(left, resource)
        |> populate_allow_filtering_conditions(right, resource)

      %{__operator__?: true} = op ->
        if involves_non_primary_key_attribute?(op, resource) do
          Map.update!(
            query,
            :__ash_bindings__,
            &Map.put(&1, :non_primary_key_attribute_filter?, true)
          )
        else
          query
        end

      %{__function__?: true, arguments: _arguments} ->
        # Skip functions for now, but cover them since fragments pass from here
        query
    end
  end

  defp involves_non_primary_key_attribute?(%{left: %{attribute: %{name: name}}}, resource) do
    name not in Ash.Resource.Info.primary_key(resource)
  end

  defp involves_non_primary_key_attribute?(%{right: %{attribute: %{name: name}}}, resource) do
    name not in Ash.Resource.Info.primary_key(resource)
  end

  defp involves_non_primary_key_attribute?(_op, _resource), do: false

  # Taken from AshPostgres/AshSqlite, it just saves the sort to apply it later
  @impl true
  def sort(query, sort, _resource) do
    {:ok, Map.update!(query, :__ash_bindings__, &Map.put(&1, :sort, sort))}
  end

  # Our tenant here is the keyspace, and Exandra supports setting it at the query level using
  # the query prefix
  @impl true
  def set_tenant(_resource, query, tenant) do
    {:ok, Map.put(Ecto.Query.put_query_prefix(query, to_string(tenant)), :__tenant__, tenant)}
  end

  # Here we take the data layer query, make all the last minute adjustments and run it agains
  # the repo
  @impl true
  def run_query(query, resource) do
    with {:ok, query} <- apply_sort(query, resource) do
      query = maybe_allow_filtering(query, resource)
      primary_key = Ash.Resource.Info.primary_key(resource)
      repo = AshSql.dynamic_repo(resource, AshScyllaDB.SqlImplementation, query)
      opts = repo_opts(repo, nil, resource)

      {:ok,
       repo.all(query, opts)
       |> Enum.uniq_by(&Map.take(&1, primary_key))}
    end
  rescue
    e ->
      handle_raised_error(e, __STACKTRACE__, query, resource)
  end

  # We silently drop sort for now to make pagination work.
  # We should instead accept sort only on clustering keys _only_ if we have
  # an equality filter (== or IN) on the clustering key, since that's the
  # only operation allowed by Scylla
  defp apply_sort(query, _resource) do
    # This should instead be:
    #
    # if query.__ash_bindings__[:sort_applied?] do
    #   {:ok, query}
    # else
    #   # :direct since ScyllaDB doesn't support :window
    #   # TODO: here is where we should check if we can sort or not
    #   AshSql.Sort.apply_sort(query, query.__ash_bindings__[:sort], resource, :direct)
    # end

    {:ok, query}
  end

  # Here we check the conditions we've set in populate_allow_filtering_conditions/3 and see if
  # we want to add ALLOW FILTERING. I'm not sure if passing it regardless causes some difference
  # in the performance in the cases where it's not needed. If it doesn't, this would
  # probably make sense as an explicit setting on the resource itself (e.g. allow_filtering? true)
  defp maybe_allow_filtering(query, _resource) do
    allow_filtering? =
      cond do
        # If we're filtering on a non primary key
        query.__ash_bindings__[:non_primary_key_attribute_filter?] ->
          true

        # Ideally we will have additional conditions in the future, e.g. filters
        # on primary keys that skip some of the primary key columns

        true ->
          false
      end

    if allow_filtering? do
      from(row in query, hints: "ALLOW FILTERING")
    else
      query
    end
  end

  # Given a type of resource and a changeset, create a record of that type
  @impl true
  def create(resource, changeset) do
    ecto_changeset =
      changeset.data
      |> Map.update!(:__meta__, &Map.put(&1, :source, table(resource, changeset)))
      |> ecto_changeset(changeset, :create)

    tenant = Map.get(changeset, :to_tenant, changeset.tenant)
    repo = AshSql.dynamic_repo(resource, AshScyllaDB.SqlImplementation, changeset)
    opts = repo_opts(repo, tenant, resource)

    try do
      repo.insert(ecto_changeset, opts)
      |> from_ecto()
      |> case do
        {:ok, record} ->
          {:ok, record}

        {:error, error} ->
          handle_errors({:error, error})
      end
    rescue
      e ->
        handle_raised_error(e, __STACKTRACE__, ecto_changeset, resource)
    end
  end

  # Given a type of resource and a changeset, update a record of that type
  @impl true
  def update(resource, changeset) do
    ecto_changeset =
      changeset.data
      |> Map.update!(:__meta__, &Map.put(&1, :source, table(resource, changeset)))
      |> ecto_changeset(changeset, :update)

    tenant = Map.get(changeset, :to_tenant, changeset.tenant)
    repo = AshSql.dynamic_repo(resource, AshScyllaDB.SqlImplementation, changeset)
    opts = repo_opts(repo, tenant, resource)

    try do
      repo.update(ecto_changeset, opts)
      |> from_ecto()
      |> case do
        {:ok, record} ->
          {:ok, record}

        {:error, error} ->
          handle_errors({:error, error})
      end
    rescue
      e ->
        handle_raised_error(e, __STACKTRACE__, ecto_changeset, resource)
    end
  end

  # Given a type of resource and a changeset, destroy a record of that type
  # Taken from AshSqlite
  @impl true
  def destroy(resource, %{data: record} = changeset) do
    ecto_changeset = ecto_changeset(record, changeset, :delete)
    tenant = Map.get(changeset, :to_tenant, changeset.tenant)
    repo = AshSql.dynamic_repo(resource, AshScyllaDB.SqlImplementation, changeset)
    opts = repo_opts(repo, tenant, resource)

    try do
      ecto_changeset
      |> repo.delete(opts)
      |> from_ecto()
      |> case do
        {:ok, _record} ->
          :ok

        {:error, error} ->
          handle_errors({:error, error})
      end
    rescue
      e ->
        handle_raised_error(e, __STACKTRACE__, ecto_changeset, resource)
    end
  end

  # Basically everything from here below is copypasted from AshPostgres or AshSqlite removing
  # stuff that is not relevant in our case (e.g. foreign key constraints etc)
  defp ecto_changeset(record, changeset, _type, _table_error? \\ true) do
    filters =
      if changeset.action_type == :create do
        %{}
      else
        Map.get(changeset, :filters, %{})
      end

    filters =
      if changeset.action_type == :create do
        filters
      else
        changeset.resource
        |> Ash.Resource.Info.primary_key()
        |> Enum.reduce(filters, fn key, filters ->
          Map.put(filters, key, Map.get(record, key))
        end)
      end

    attributes =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    attributes_to_change =
      Enum.reject(attributes, fn attribute ->
        Keyword.has_key?(changeset.atomics, attribute)
      end)

    record
    |> to_ecto()
    |> Ecto.Changeset.change(Map.take(changeset.attributes, attributes_to_change))
    |> Map.update!(:filters, &Map.merge(&1, filters))
    |> add_unique_indexes(record.__struct__, changeset)
  end

  defp repo_opts(repo, tenant, resource) do
    AshSql.repo_opts(repo, AshScyllaDB.SqlImplementation, nil, tenant, resource)
  end

  # to_ecto and from_ecto are needed to convert back and forth records in the
  # Ecto and Ash format. The differences between the two are basically some metadata
  # and the type of structs for, e.g., not loaded fields
  def to_ecto(nil), do: nil

  def to_ecto(value) when is_list(value) do
    Enum.map(value, &to_ecto/1)
  end

  def to_ecto(%resource{} = record) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce(record, fn relationship, record ->
        value =
          case Map.get(record, relationship.name) do
            %Ash.NotLoaded{} ->
              %Ecto.Association.NotLoaded{
                __field__: relationship.name,
                __cardinality__: relationship.cardinality
              }

            value ->
              to_ecto(value)
          end

        Map.put(record, relationship.name, value)
      end)
    else
      record
    end
  end

  def to_ecto(other), do: other

  def from_ecto({:ok, result}), do: {:ok, from_ecto(result)}
  def from_ecto({:error, _} = other), do: other

  def from_ecto(nil), do: nil

  def from_ecto(value) when is_list(value) do
    Enum.map(value, &from_ecto/1)
  end

  def from_ecto(%resource{} = record) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      empty = struct(resource)

      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce(record, fn relationship, record ->
        case Map.get(record, relationship.name) do
          %Ecto.Association.NotLoaded{} ->
            Map.put(record, relationship.name, Map.get(empty, relationship.name))

          value ->
            Map.put(record, relationship.name, from_ecto(value))
        end
      end)
    else
      record
    end
  end

  def from_ecto(other), do: other

  # Here we convert from Ecto Changeset errors to Ash errors
  defp handle_errors({:error, %Ecto.Changeset{errors: errors}}) do
    {:error, Enum.map(errors, &to_ash_error/1)}
  end

  defp to_ash_error({field, {message, vars}}) do
    Ash.Error.Changes.InvalidAttribute.exception(
      field: field,
      message: message,
      private_vars: vars
    )
  end

  defp table(resource, changeset) do
    changeset.context[:data_layer][:table] || AshScyllaDB.DataLayer.Info.table(resource)
  end

  defp add_unique_indexes(changeset, resource, ash_changeset) do
    names =
      case Ash.Resource.Info.primary_key(resource) do
        [] ->
          []

        fields ->
          if table = table(resource, ash_changeset) do
            [{fields, table <> "_pkey"}]
          else
            []
          end
      end

    Enum.reduce(names, changeset, fn
      {keys, name}, changeset ->
        Ecto.Changeset.unique_constraint(changeset, List.wrap(keys), name: name)

      {keys, name, message}, changeset ->
        Ecto.Changeset.unique_constraint(changeset, List.wrap(keys), name: name, message: message)
    end)
  end

  defp handle_raised_error(
         %Ecto.StaleEntryError{changeset: %{data: %resource{}, filters: filters}},
         stacktrace,
         context,
         resource
       ) do
    handle_raised_error(
      Ash.Error.Changes.StaleRecord.exception(resource: resource, filters: filters),
      stacktrace,
      context,
      resource
    )
  end

  defp handle_raised_error(%Ecto.Query.CastError{} = e, stacktrace, context, resource) do
    handle_raised_error(
      Ash.Error.Query.InvalidFilterValue.exception(value: e.value, context: context),
      stacktrace,
      context,
      resource
    )
  end

  defp handle_raised_error(error, stacktrace, _ecto_changeset, _resource) do
    {:error, Ash.Error.to_ash_error(error, stacktrace)}
  end
end
