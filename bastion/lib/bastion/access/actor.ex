defmodule Bastion.Access.Actor do
  alias Bastion.Access.Domain.Actions

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          username: String.t(),
          global: MapSet.t(String.t()),
          folders: %{String.t() => MapSet.t(String.t())}
        }
  defstruct [:user_id, :username, global: MapSet.new(), folders: %{}]

  @type path :: [String.t()]

  @spec superadmin?(t()) :: boolean()
  def superadmin?(%__MODULE__{global: global}), do: "superadmin" in global

  @spec can?(t(), String.t()) :: boolean()
  def can?(%__MODULE__{global: global}, action), do: action in global

  @spec can?(t(), String.t(), [path()]) :: boolean()
  def can?(%__MODULE__{} = actor, action, paths) do
    can?(actor, action) or
      (not Actions.global?(action) and Enum.any?(paths, &path_allows?(actor, action, &1)))
  end

  @spec can_all?(t(), String.t(), [path()]) :: boolean()
  def can_all?(%__MODULE__{} = actor, action, paths) do
    can?(actor, action) or
      (not Actions.global?(action) and Enum.all?(paths, &path_allows?(actor, action, &1)))
  end

  defp path_allows?(actor, action, path) do
    Enum.any?(path, fn id ->
      case actor.folders do
        %{^id => actions} -> action in actions
        _ -> false
      end
    end)
  end

  @spec granted_folder_ids(t(), String.t()) :: [String.t()]
  def granted_folder_ids(%__MODULE__{folders: folders}, action) do
    for {id, actions} <- folders, action in actions, do: id
  end
end
