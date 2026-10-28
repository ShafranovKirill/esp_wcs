defmodule Bastion.Access do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Repo, Bastion.Events],
    exports: [Actor, Role, Group, Grant, Events.GrantsChanged]

  alias Bastion.Access.Application.{Management, Resolver}
  alias Bastion.Access.Domain.Actions
  alias Bastion.Access.Infrastructure.{GrantRecord, RoleRecord}
  alias Bastion.Repo

  def subscribe, do: Bastion.Events.subscribe(:access)

  defdelegate actions(), to: Actions, as: :all
  defdelegate folder_actions(), to: Actions, as: :folder
  defdelegate global_actions(), to: Actions, as: :global
  defdelegate normalize_actions(actions), to: Actions, as: :normalize

  defdelegate actor(user), to: Resolver
  defdelegate system(), to: Resolver
  defdelegate superadmin_user_ids(), to: Resolver

  defdelegate can?(actor, action), to: Bastion.Access.Actor
  defdelegate can?(actor, action, paths), to: Bastion.Access.Actor
  defdelegate can_all?(actor, action, paths), to: Bastion.Access.Actor

  @spec authorize(Bastion.Access.Actor.t(), String.t(), [[String.t()]] | :global) ::
          :ok | {:error, :forbidden}
  def authorize(actor, action, :global),
    do: if(can?(actor, action), do: :ok, else: {:error, :forbidden})

  def authorize(actor, action, paths),
    do: if(can?(actor, action, paths), do: :ok, else: {:error, :forbidden})

  defdelegate list_roles(), to: Management
  defdelegate list_groups(), to: Management
  defdelegate list_grants(), to: Management
  defdelegate create_role(actor, name, actions), to: Management
  defdelegate update_role(actor, id, name, actions), to: Management
  defdelegate delete_role(actor, id), to: Management
  defdelegate create_group(actor, name), to: Management
  defdelegate rename_group(actor, id, name), to: Management
  defdelegate delete_group(actor, id), to: Management
  defdelegate add_member(actor, group_id, user_id), to: Management
  defdelegate remove_member(actor, group_id, user_id), to: Management
  defdelegate grant(actor, attrs), to: Management
  defdelegate revoke(actor, id), to: Management

  @spec grant_superadmin(String.t()) :: :ok
  def grant_superadmin(user_id) do
    role = Repo.get_by!(RoleRecord, builtin: "superadmin")

    unless user_id in Resolver.superadmin_user_ids() do
      Repo.insert!(%GrantRecord{role_id: role.id, user_id: user_id})
      Bastion.Events.publish(:access, %Bastion.Access.Events.GrantsChanged{})
    end

    :ok
  end
end
