defmodule Bastion.Access.Application.Management do
  import Ecto.Query

  alias Bastion.Access.Actor
  alias Bastion.Access.Application.Resolver
  alias Bastion.Access.Domain.Actions
  alias Bastion.Access.Events.GrantsChanged
  alias Bastion.Access.{Grant, Group, Role}
  alias Bastion.Access.Infrastructure.{GrantRecord, GroupRecord, RoleRecord}
  alias Bastion.Repo

  @name_max 64

  @spec list_roles() :: [Role.t()]
  def list_roles do
    Repo.all(
      from r in RoleRecord, order_by: [asc: is_nil(r.builtin), asc: fragment("lower(?)", r.name)]
    )
    |> Enum.map(&RoleRecord.to_domain/1)
  end

  @spec list_groups() :: [Group.t()]
  def list_groups do
    members =
      Repo.all(
        from m in "group_members",
          select: {type(m.group_id, :binary_id), type(m.user_id, :binary_id)}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Repo.all(from g in GroupRecord, order_by: fragment("lower(?)", g.name))
    |> Enum.map(&%Group{id: &1.id, name: &1.name, member_ids: Map.get(members, &1.id, [])})
  end

  @spec list_grants() :: [Grant.t()]
  def list_grants do
    Repo.all(from g in GrantRecord, order_by: g.inserted_at) |> Enum.map(&GrantRecord.to_domain/1)
  end

  @spec create_role(Actor.t(), String.t(), [String.t()]) :: {:ok, Role.t()} | {:error, atom()}
  def create_role(actor, name, actions) do
    with :ok <- allow(actor, "roles.manage"),
         {:ok, name} <- name(name),
         :ok <- superadmin_only(actor, actions) do
      %RoleRecord{}
      |> RoleRecord.changeset(%{name: name, actions: Actions.normalize(actions)})
      |> Repo.insert()
      |> saved(actor, :role_created)
    end
  end

  @spec update_role(Actor.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, Role.t()} | {:error, atom()}
  def update_role(actor, id, name, actions) do
    with :ok <- allow(actor, "roles.manage"),
         {:ok, record} <- fetch(RoleRecord, id, :role_not_found),
         :ok <- editable(record),
         {:ok, name} <- name(name),
         :ok <- superadmin_only(actor, actions) do
      guarded(fn ->
        record
        |> RoleRecord.changeset(%{name: name, actions: Actions.normalize(actions)})
        |> Repo.update()
      end)
      |> saved(actor, :role_updated)
    end
  end

  @spec delete_role(Actor.t(), String.t()) :: :ok | {:error, atom()}
  def delete_role(actor, id) do
    with :ok <- allow(actor, "roles.manage"),
         {:ok, record} <- fetch(RoleRecord, id, :role_not_found),
         true <- is_nil(record.builtin) || {:error, :builtin_role} do
      guarded(fn -> {:ok, Repo.delete!(record)} end)
      |> done(actor, :role_deleted, nil, %{role: record.name})
    end
  end

  @spec create_group(Actor.t(), String.t()) :: {:ok, Group.t()} | {:error, atom()}
  def create_group(actor, name) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, name} <- name(name) do
      %GroupRecord{}
      |> GroupRecord.changeset(%{name: name})
      |> Repo.insert()
      |> case do
        {:ok, record} ->
          changed({:ok, %Group{id: record.id, name: record.name}}, actor, :group_created, nil, %{
            group: record.name
          })

        {:error, _} ->
          {:error, :name_taken}
      end
    end
  end

  @spec rename_group(Actor.t(), String.t(), String.t()) :: {:ok, Group.t()} | {:error, atom()}
  def rename_group(actor, id, name) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, record} <- fetch(GroupRecord, id, :group_not_found),
         {:ok, name} <- name(name) do
      before = record.name

      record
      |> GroupRecord.changeset(%{name: name})
      |> Repo.update()
      |> case do
        {:ok, record} ->
          changed({:ok, %Group{id: record.id, name: record.name}}, actor, :group_renamed, nil, %{
            from: before,
            group: record.name
          })

        {:error, _} ->
          {:error, :name_taken}
      end
    end
  end

  @spec delete_group(Actor.t(), String.t()) :: :ok | {:error, atom()}
  def delete_group(actor, id) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, record} <- fetch(GroupRecord, id, :group_not_found) do
      guarded(fn -> {:ok, Repo.delete!(record)} end)
      |> done(actor, :group_deleted, nil, %{group: record.name})
    end
  end

  @spec add_member(Actor.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def add_member(actor, group_id, user_id) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, group} <- fetch(GroupRecord, group_id, :group_not_found),
         {:ok, user_id} <- cast(user_id, :user_not_found),
         :ok <- superadmin_group(actor, group.id) do
      Repo.insert_all(
        "group_members",
        [%{group_id: dump(group.id), user_id: dump(user_id)}],
        on_conflict: :nothing
      )

      changed(:ok, actor, :member_added, user_id, %{group: group.name})
    end
  rescue
    Postgrex.Error -> {:error, :user_not_found}
  end

  @spec remove_member(Actor.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def remove_member(actor, group_id, user_id) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, group} <- fetch(GroupRecord, group_id, :group_not_found),
         {:ok, user_id} <- cast(user_id, :user_not_found),
         :ok <- superadmin_group(actor, group.id) do
      guarded(fn ->
        Repo.delete_all(
          from m in "group_members",
            where:
              m.group_id == type(^group.id, :binary_id) and
                m.user_id == type(^user_id, :binary_id)
        )

        {:ok, :ok}
      end)
      |> done(actor, :member_removed, user_id, %{group: group.name})
    end
  end

  @spec grant(Actor.t(), map()) :: {:ok, Grant.t()} | {:error, atom()}
  def grant(actor, attrs) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, role} <- fetch(RoleRecord, attrs[:role_id], :role_not_found),
         :ok <- superadmin_only(actor, role.actions),
         {:ok, grantee} <- grantee(attrs),
         {:ok, folder_id} <- optional(attrs[:folder_id], :folder_not_found),
         :ok <- folder_scope(role, folder_id) do
      %GrantRecord{}
      |> GrantRecord.changeset(Map.merge(grantee, %{role_id: role.id, folder_id: folder_id}))
      |> Repo.insert()
      |> case do
        {:ok, record} ->
          changed(
            {:ok, GrantRecord.to_domain(record)},
            actor,
            :access_granted,
            record.user_id,
            grant_data(record, role)
          )

        {:error, changeset} ->
          cond do
            Keyword.has_key?(changeset.errors, :folder_id) -> {:error, :folder_not_found}
            Keyword.has_key?(changeset.errors, :user_id) -> {:error, :user_not_found}
            Keyword.has_key?(changeset.errors, :group_id) -> {:error, :group_not_found}
            true -> {:error, :grant_exists}
          end
      end
    end
  end

  @spec revoke(Actor.t(), String.t()) :: :ok | {:error, atom()}
  def revoke(actor, id) do
    with :ok <- allow(actor, "users.manage"),
         {:ok, record} <- fetch(GrantRecord, id, :grant_not_found),
         {:ok, role} <- fetch(RoleRecord, record.role_id, :role_not_found),
         :ok <- superadmin_only(actor, role.actions) do
      guarded(fn -> {:ok, Repo.delete!(record)} end)
      |> done(actor, :access_revoked, record.user_id, grant_data(record, role))
    end
  end

  defp folder_scope(_role, nil), do: :ok

  defp folder_scope(role, _folder_id) do
    if Enum.any?(role.actions, &(not Actions.global?(&1))),
      do: :ok,
      else: {:error, :global_role}
  end

  defp grantee(%{user_id: id}) when is_binary(id) and id != "" do
    with {:ok, id} <- cast(id, :user_not_found), do: {:ok, %{user_id: id, group_id: nil}}
  end

  defp grantee(%{group_id: id}) when is_binary(id) and id != "" do
    with {:ok, record} <- fetch(GroupRecord, id, :group_not_found),
         do: {:ok, %{user_id: nil, group_id: record.id}}
  end

  defp grantee(_), do: {:error, :grantee_required}

  defp optional(nil, _), do: {:ok, nil}
  defp optional("", _), do: {:ok, nil}
  defp optional(id, error), do: cast(id, error)

  defp allow(actor, action),
    do: if(Actor.can?(actor, action), do: :ok, else: {:error, :forbidden})

  defp superadmin_only(actor, actions) do
    if "superadmin" in actions and not Actor.superadmin?(actor),
      do: {:error, :forbidden},
      else: :ok
  end

  defp superadmin_group(actor, group_id) do
    grants_superadmin? =
      Repo.exists?(
        from g in GrantRecord,
          join: r in RoleRecord,
          on: r.id == g.role_id,
          where: g.group_id == ^group_id and "superadmin" in r.actions
      )

    if grants_superadmin? and not Actor.superadmin?(actor), do: {:error, :forbidden}, else: :ok
  end

  defp editable(%RoleRecord{builtin: "superadmin"}), do: {:error, :builtin_role}
  defp editable(_), do: :ok

  defp guarded(fun) do
    Repo.transaction(fn ->
      had_superadmin? = Resolver.superadmin_user_ids() != []

      case fun.() do
        {:ok, result} ->
          if had_superadmin? and Resolver.superadmin_user_ids() == [],
            do: Repo.rollback(:last_superadmin),
            else: result

        {:error, %Ecto.Changeset{}} ->
          Repo.rollback(:name_taken)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp saved({:ok, %RoleRecord{} = record}, actor, change) do
    changed({:ok, RoleRecord.to_domain(record)}, actor, change, nil, %{
      role: record.name,
      actions: record.actions
    })
  end

  defp saved({:error, %Ecto.Changeset{}}, _actor, _change), do: {:error, :name_taken}
  defp saved({:error, reason}, _actor, _change), do: {:error, reason}

  defp done({:ok, _}, actor, change, user_id, data),
    do: changed(:ok, actor, change, user_id, data)

  defp done({:error, reason}, _actor, _change, _user_id, _data), do: {:error, reason}

  defp changed(result, actor, change, user_id, data) do
    Bastion.Events.publish(:access, %GrantsChanged{
      change: change,
      actor_id: actor.user_id,
      user_id: user_id,
      data: data
    })

    result
  end

  defp grant_data(record, role) do
    group = record.group_id && Repo.get(GroupRecord, record.group_id)

    %{role: role.name, folder_id: record.folder_id, group: group && group.name}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp name(name) do
    name = name |> to_string() |> String.trim() |> String.replace(~r/\s+/u, " ")

    cond do
      name == "" -> {:error, :blank}
      String.length(name) > @name_max -> {:error, :too_long}
      true -> {:ok, name}
    end
  end

  defp fetch(schema, id, error) do
    with {:ok, uuid} <- cast(id, error),
         %{} = record <- Repo.get(schema, uuid) do
      {:ok, record}
    else
      _ -> {:error, error}
    end
  end

  defp cast(id, error) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
