defmodule Bastion.Fleet.Application.FolderCommands do
  import Ecto.Query

  alias Bastion.Fleet.Application.UnitOfWork
  alias Bastion.Fleet.Domain.Name
  alias Bastion.Fleet.Events.FoldersChanged
  alias Bastion.Fleet.Folder
  alias Bastion.Fleet.Infrastructure.FolderRecord
  alias Bastion.Repo

  @spec create(String.t(), String.t() | nil) :: {:ok, Folder.t()} | {:error, atom()}
  def create(name, parent_id \\ nil) do
    with {:ok, name} <- Name.normalize(name) do
      UnitOfWork.run(fn ->
        with {:ok, parent} <- parent(parent_id),
             :ok <- check_depth(parent, 1) do
          id = Ecto.UUID.generate()
          path = if parent, do: parent.path <> "/" <> id, else: id

          %FolderRecord{id: id}
          |> FolderRecord.changeset(%{name: name, parent_id: parent && parent.id, path: path})
          |> Repo.insert()
          |> result()
        end
      end)
    end
  end

  @spec rename(String.t(), String.t()) :: {:ok, Folder.t()} | {:error, atom()}
  def rename(id, name) do
    with {:ok, name} <- Name.normalize(name),
         {:ok, record} <- get(id) do
      UnitOfWork.run(fn ->
        record |> FolderRecord.changeset(%{name: name}) |> Repo.update() |> result()
      end)
    end
  end

  @spec move(String.t(), String.t() | nil) :: {:ok, Folder.t()} | {:error, atom()}
  def move(id, parent_id) do
    UnitOfWork.run(fn ->
      with {:ok, record} <- lock(id),
           {:ok, parent} <- parent(parent_id),
           :ok <- check_not_inside(record, parent),
           :ok <- check_depth(parent, subtree_height(record)) do
        if record.parent_id == (parent && parent.id) do
          {:ok, FolderRecord.to_domain(record), []}
        else
          old = record.path
          new = if parent, do: parent.path <> "/" <> record.id, else: record.id

          with {:ok, moved} <-
                 record
                 |> FolderRecord.changeset(%{parent_id: parent && parent.id, path: new})
                 |> Repo.update() do
            Repo.update_all(
              from(f in FolderRecord, where: like(f.path, ^(escape(old) <> "/%"))),
              set: [
                path:
                  dynamic([f], fragment("? || substr(?, ?)", ^new, f.path, ^(byte_size(old) + 1)))
              ]
            )

            result({:ok, moved})
          else
            error -> result(error)
          end
        end
      end
    end)
  end

  @spec delete(String.t()) :: :ok | {:error, :folder_not_found | :folder_not_empty}
  def delete(id) do
    UnitOfWork.run(fn ->
      with {:ok, record} <- lock(id) do
        cond do
          Repo.exists?(from f in FolderRecord, where: f.parent_id == ^record.id) ->
            {:error, :folder_not_empty}

          Repo.exists?(
            from m in "device_folders", where: m.folder_id == type(^record.id, :binary_id)
          ) ->
            {:error, :folder_not_empty}

          true ->
            Repo.delete!(record)
            {:ok, :ok, [{:fleet, %FoldersChanged{}}]}
        end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp parent(nil), do: {:ok, nil}
  defp parent(""), do: {:ok, nil}

  defp parent(id) do
    case get(id) do
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:error, :folder_not_found}
    end
  end

  defp check_depth(nil, height), do: if(height <= Folder.max_depth(), do: :ok, else: too_deep())

  defp check_depth(parent, height) do
    if length(FolderRecord.split_path(parent.path)) + height <= Folder.max_depth(),
      do: :ok,
      else: too_deep()
  end

  defp too_deep, do: {:error, :folder_too_deep}

  defp check_not_inside(_record, nil), do: :ok

  defp check_not_inside(record, parent) do
    if parent.id == record.id or String.starts_with?(parent.path, record.path <> "/"),
      do: {:error, :folder_into_itself},
      else: :ok
  end

  defp subtree_height(record) do
    base = length(FolderRecord.split_path(record.path))

    Repo.all(
      from f in FolderRecord,
        where: f.path == ^record.path or like(f.path, ^(escape(record.path) <> "/%")),
        select: f.path
    )
    |> Enum.map(&(length(FolderRecord.split_path(&1)) - base + 1))
    |> Enum.max(fn -> 1 end)
  end

  defp escape(path), do: String.replace(path, ~r/[\\%_]/, "\\\\\\0")

  defp get(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %FolderRecord{} = record <- Repo.get(FolderRecord, uuid) do
      {:ok, record}
    else
      _ -> {:error, :folder_not_found}
    end
  end

  defp lock(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %FolderRecord{} = record <-
           Repo.one(from f in FolderRecord, where: f.id == ^uuid, lock: "FOR UPDATE") do
      {:ok, record}
    else
      _ -> {:error, :folder_not_found}
    end
  end

  defp result({:ok, record}),
    do: {:ok, FolderRecord.to_domain(record), [{:fleet, %FoldersChanged{}}]}

  defp result({:error, %Ecto.Changeset{} = changeset}) do
    if Keyword.has_key?(changeset.errors, :name),
      do: {:error, :name_taken},
      else: {:error, :folder_not_found}
  end
end
