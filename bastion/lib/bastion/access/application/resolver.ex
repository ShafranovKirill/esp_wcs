defmodule Bastion.Access.Application.Resolver do
  import Ecto.Query

  alias Bastion.Access.Actor
  alias Bastion.Access.Domain.Actions
  alias Bastion.Access.Infrastructure.{GrantRecord, RoleRecord}
  alias Bastion.Repo

  @spec actor(%{id: String.t(), username: String.t()}) :: Actor.t()
  def actor(%{id: user_id, username: username}) do
    rows =
      Repo.all(
        from g in GrantRecord,
          join: r in RoleRecord,
          on: r.id == g.role_id,
          where:
            g.user_id == ^user_id or
              g.group_id in subquery(
                from m in "group_members",
                  where: m.user_id == type(^user_id, :binary_id),
                  select: m.group_id
              ),
          select: {g.folder_id, r.actions}
      )

    {global, by_folder} =
      Enum.reduce(rows, {[], %{}}, fn
        {nil, actions}, {global, folders} ->
          {actions ++ global, folders}

        {folder_id, actions}, {global, folders} ->
          {global, Map.update(folders, folder_id, actions, &(actions ++ &1))}
      end)

    global = Actions.expand(global)

    folders =
      Map.new(by_folder, fn {id, actions} ->
        {id, actions |> Enum.reject(&Actions.global?/1) |> Actions.expand()}
      end)

    %Actor{user_id: user_id, username: username, global: global, folders: folders}
  end

  @spec system() :: Actor.t()
  def system,
    do: %Actor{user_id: nil, username: "system", global: Actions.expand(["superadmin"])}

  @spec superadmin_user_ids() :: [String.t()]
  def superadmin_user_ids do
    roles = from r in RoleRecord, where: "superadmin" in r.actions, select: r.id

    direct =
      Repo.all(
        from g in GrantRecord,
          where: g.role_id in subquery(roles) and is_nil(g.folder_id) and not is_nil(g.user_id),
          select: g.user_id
      )

    via_groups =
      Repo.all(
        from g in GrantRecord,
          join: m in "group_members",
          on: m.group_id == g.group_id,
          where: g.role_id in subquery(roles) and is_nil(g.folder_id),
          select: type(m.user_id, :binary_id)
      )

    Enum.uniq(direct ++ via_groups)
  end
end
