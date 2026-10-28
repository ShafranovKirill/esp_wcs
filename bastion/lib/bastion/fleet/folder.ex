defmodule Bastion.Fleet.Folder do
  @max_depth 8

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          parent_id: String.t() | nil,
          path: [String.t()]
        }
  defstruct [:id, :name, :parent_id, path: []]

  @type node_t :: {t(), [node_t()]}

  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @spec depth(t()) :: pos_integer()
  def depth(%__MODULE__{path: path}), do: length(path)

  @spec inside?(t(), t() | String.t()) :: boolean()
  def inside?(%__MODULE__{path: path}, %__MODULE__{id: id}), do: id in path
  def inside?(%__MODULE__{path: path}, id) when is_binary(id), do: id in path

  @spec tree([t()]) :: [node_t()]
  def tree(folders) do
    children = Enum.group_by(folders, & &1.parent_id)
    build(children, nil)
  end

  defp build(children, parent_id) do
    children
    |> Map.get(parent_id, [])
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(&{&1, build(children, &1.id)})
  end

  @spec flatten([node_t()]) :: [t()]
  def flatten(nodes), do: Enum.flat_map(nodes, fn {f, kids} -> [f | flatten(kids)] end)

  @spec full_name(t(), %{String.t() => t()}) :: String.t()
  def full_name(%__MODULE__{path: path}, by_id) do
    path
    |> Enum.map(&(by_id[&1] && by_id[&1].name))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end
end
