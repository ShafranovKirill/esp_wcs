defmodule Bastion.Fleet.Application.FolderCommands do
  alias Bastion.Fleet.Application.UnitOfWork
  alias Bastion.Fleet.Domain.Name
  alias Bastion.Fleet.Events.FoldersChanged
  alias Bastion.Fleet.Folder
  alias Bastion.Fleet.Infrastructure.FolderRecord
  alias Bastion.Repo

  @spec create(String.t()) :: {:ok, Folder.t()} | {:error, atom()}
  def create(name) do
    with {:ok, name} <- Name.normalize(name) do
      UnitOfWork.run(fn ->
        %FolderRecord{} |> FolderRecord.changeset(name) |> Repo.insert() |> result()
      end)
    end
  end

  @spec rename(String.t(), String.t()) :: {:ok, Folder.t()} | {:error, atom()}
  def rename(id, name) do
    with {:ok, name} <- Name.normalize(name),
         {:ok, record} <- get(id) do
      UnitOfWork.run(fn ->
        record |> FolderRecord.changeset(name) |> Repo.update() |> result()
      end)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(id) do
    with {:ok, record} <- get(id) do
      {:ok, :ok} =
        UnitOfWork.run(fn ->
          {:ok, Repo.delete!(record) && :ok, [{:fleet, %FoldersChanged{}}]}
        end)

      :ok
    end
  end

  defp get(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %FolderRecord{} = record <- Repo.get(FolderRecord, uuid) do
      {:ok, record}
    else
      _ -> {:error, :not_found}
    end
  end

  defp result({:ok, record}),
    do: {:ok, FolderRecord.to_domain(record), [{:fleet, %FoldersChanged{}}]}

  defp result({:error, _changeset}), do: {:error, :name_taken}
end
