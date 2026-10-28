defmodule Bastion.Access.Domain.Actions do
  @folder ~w(view console.read console.write device.configure device.wifi device.reboot device.revoke folder.manage)
  @global ~w(enrollment.approve users.manage roles.manage superadmin)

  @spec all() :: [String.t()]
  def all, do: @folder ++ @global

  @spec folder() :: [String.t()]
  def folder, do: @folder

  @spec global() :: [String.t()]
  def global, do: @global

  @spec global?(String.t()) :: boolean()
  def global?(action), do: action in @global

  @spec expand([String.t()]) :: MapSet.t(String.t())
  def expand(actions) do
    actions = Enum.filter(actions, &(&1 in all()))

    actions
    |> Enum.flat_map(&implied/1)
    |> Enum.concat(actions)
    |> MapSet.new()
  end

  defp implied("superadmin"), do: all()
  defp implied("console.write"), do: ["console.read", "view"]
  defp implied(action) when action in @folder, do: ["view"]
  defp implied(_), do: []

  @spec normalize([String.t()]) :: [String.t()]
  def normalize(actions) do
    set = expand(actions)
    if "superadmin" in set, do: ["superadmin"], else: Enum.filter(all(), &(&1 in set))
  end
end
