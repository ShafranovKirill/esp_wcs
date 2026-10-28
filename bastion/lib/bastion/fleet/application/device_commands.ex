defmodule Bastion.Fleet.Application.DeviceCommands do
  import Ecto.Query

  alias Bastion.Fleet.Application.{Policy, UnitOfWork}
  alias Bastion.Fleet.Device
  alias Bastion.Fleet.Domain.{DeviceId, Name}
  alias Bastion.Fleet.Events.{DeviceApproved, DeviceChanged, DeviceRequested, DeviceRevoked}
  alias Bastion.Fleet.Infrastructure.{DeviceEventRecord, DeviceRecord, FolderRecord}
  alias Bastion.Access.Actor
  alias Bastion.Repo

  @type request_attrs :: %{
          required(:device_id) => String.t(),
          required(:name) => String.t(),
          required(:csr_pem) => String.t(),
          optional(:firmware_version) => String.t() | nil,
          optional(:ip) => String.t() | nil
        }

  @spec submit_request(request_attrs()) ::
          {:ok, :pending} | {:ok, {:approved, String.t()}} | {:error, atom()}
  def submit_request(attrs) do
    with {:ok, device_id} <- DeviceId.normalize(attrs[:device_id]),
         {:ok, code} <- Bastion.PKI.check_device_csr(attrs[:csr_pem], device_id) do
      req = %{
        device_id: device_id,
        name: default_name(attrs[:name], device_id),
        device_code: code,
        csr_pem: attrs[:csr_pem],
        firmware_version: attrs[:firmware_version],
        ip: attrs[:ip]
      }

      UnitOfWork.run(fn -> do_submit(req) end)
    end
  end

  defp do_submit(req) do
    record = lock_by_device_id(req.device_id)

    with :ok <- check_capacity(record) do
      request(record, req, now())
    end
  end

  defp check_capacity(nil) do
    cond do
      Repo.aggregate(DeviceRecord, :count) >= Device.max_devices() -> {:error, :fleet_full}
      pending_count() >= Device.max_pending() -> {:error, :too_many_requests}
      true -> :ok
    end
  end

  defp check_capacity(%DeviceRecord{status: :pending}), do: :ok

  defp check_capacity(_record) do
    if pending_count() >= Device.max_pending(), do: {:error, :too_many_requests}, else: :ok
  end

  defp pending_count do
    status = :pending
    Repo.aggregate(from(d in DeviceRecord, where: d.status == ^status), :count)
  end

  defp request(record, req, now) do
    case Device.request(record && DeviceRecord.to_domain(record), req, now) do
      {:ok, device} ->
        with {:ok, saved} <- save_request(record, device) do
          journal(saved.id, :requested, %{code: saved.device_code, ip: saved.last_ip})

          {:ok, :pending,
           [
             {[:fleet, {:device, saved.id}],
              %DeviceRequested{id: saved.id, device_id: saved.device_id}},
             changed(saved.id, :requested)
           ]}
        end

      {:already_approved, device} ->
        {:ok, {:approved, device.certificate_pem}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_request(nil, device) do
    name =
      if name_taken?(device.name),
        do: device.name <> "-" <> String.slice(device.device_id, -4, 4),
        else: device.name

    create(%{device | name: name})
  end

  defp save_request(record, device), do: persist(record, device)

  defp default_name(name, device_id) do
    case Name.normalize(name) do
      {:ok, name} -> name
      {:error, _} -> "esp-wcs-" <> String.slice(device_id, -4, 4)
    end
  end

  @spec approve(Actor.t(), String.t(), String.t()) :: {:ok, Device.t()} | {:error, atom()}
  def approve(actor, id, device_code) do
    UnitOfWork.run(fn ->
      with :ok <- Policy.authorize_global(actor, "enrollment.approve"),
           {:ok, record} <- lock(id),
           device = DeviceRecord.to_domain(record),
           true <- device.device_code == device_code || {:error, :code_changed},
           {:ok, cert} <- sign(device),
           {:ok, device} <- Device.approve(device, cert, now()),
           {:ok, saved} <- persist(record, device) do
        journal(saved.id, :approved, %{serial: saved.certificate_serial}, actor)

        {:ok, saved,
         [
           {[:fleet, {:device, saved.id}],
            %DeviceApproved{
              id: saved.id,
              device_id: saved.device_id,
              certificate_pem: saved.certificate_pem
            }},
           changed(saved.id, :approved)
         ]}
      end
    end)
  end

  defp sign(%Device{status: :pending, csr_pem: csr, device_id: device_id}) when is_binary(csr),
    do: Bastion.PKI.sign_device_csr(csr, device_id)

  defp sign(_device), do: {:error, :not_pending}

  @spec reject(Actor.t(), String.t()) :: {:ok, :deleted | Device.t()} | {:error, atom()}
  def reject(actor, id) do
    UnitOfWork.run(fn ->
      with :ok <- Policy.authorize_global(actor, "enrollment.approve"),
           {:ok, record} <- lock(id) do
        case Device.reject(DeviceRecord.to_domain(record), now()) do
          :delete ->
            Repo.delete!(record)
            {:ok, :deleted, [changed(id, :deleted)]}

          {:ok, device} ->
            with {:ok, saved} <- persist(record, device) do
              journal(saved.id, :rejected, %{}, actor)
              {:ok, saved, [changed(saved.id, :rejected)]}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  @spec revoke(Actor.t(), String.t()) :: {:ok, Device.t()} | {:error, atom()}
  def revoke(actor, id) do
    UnitOfWork.run(fn ->
      with {:ok, record} <- lock(id),
           :ok <- Policy.authorize(actor, "device.revoke", DeviceRecord.to_domain(record)),
           {:ok, device} <- Device.revoke(DeviceRecord.to_domain(record), now()),
           {:ok, saved} <- persist(record, device) do
        journal(saved.id, :revoked, %{serial: record.certificate_serial}, actor)

        {:ok, saved,
         [
           {[:fleet, {:device, saved.id}],
            %DeviceRevoked{id: saved.id, device_id: saved.device_id}},
           changed(saved.id, :revoked)
         ]}
      end
    end)
  end

  @spec delete(Actor.t(), String.t()) :: {:ok, :deleted} | {:error, atom()}
  def delete(actor, id) do
    UnitOfWork.run(fn ->
      with {:ok, record} <- lock(id),
           :ok <- Policy.authorize(actor, "device.revoke", DeviceRecord.to_domain(record)),
           :delete <- Device.delete(DeviceRecord.to_domain(record)) do
        Repo.delete!(record)
        {:ok, :deleted, [changed(id, :deleted)]}
      end
    end)
  end

  @spec rename(Actor.t(), String.t(), String.t()) :: {:ok, Device.t()} | {:error, atom()}
  def rename(actor, id, name) do
    UnitOfWork.run(fn ->
      with {:ok, name} <- Name.normalize(name),
           {:ok, record} <- lock(id),
           :ok <- Policy.authorize(actor, "device.configure", DeviceRecord.to_domain(record)) do
        if record.name == name do
          {:ok, DeviceRecord.to_domain(record), []}
        else
          with {:ok, saved} <- persist(record, %{DeviceRecord.to_domain(record) | name: name}) do
            journal(saved.id, :renamed, %{from: record.name, to: name}, actor)
            {:ok, saved, [changed(saved.id, :renamed)]}
          end
        end
      end
    end)
  end

  @spec set_folders(Actor.t(), String.t(), [String.t()]) :: {:ok, Device.t()} | {:error, atom()}
  def set_folders(actor, id, folder_ids) do
    UnitOfWork.run(fn ->
      with {:ok, record} <- lock(id),
           :ok <- Policy.authorize(actor, "device.configure", DeviceRecord.to_domain(record)),
           {:ok, folders} <- folders(folder_ids),
           :ok <- authorize_membership(actor, record.folders, folders) do
        before = record.folders |> Enum.map(& &1.id) |> Enum.sort()

        if before == Enum.map(folders, & &1.id) do
          {:ok, DeviceRecord.to_domain(record), []}
        else
          saved =
            record
            |> Ecto.Changeset.change()
            |> Ecto.Changeset.put_assoc(:folders, folders)
            |> Repo.update!()

          journal(saved.id, :moved, %{folders: Enum.map(folders, & &1.name)}, actor)
          {:ok, DeviceRecord.to_domain(saved), [changed(saved.id, :moved)]}
        end
      end
    end)
  end

  defp authorize_membership(actor, before, after_) do
    before_ids = MapSet.new(before, & &1.id)
    after_ids = MapSet.new(after_, & &1.id)

    (before ++ after_)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&(MapSet.member?(before_ids, &1.id) != MapSet.member?(after_ids, &1.id)))
    |> Enum.reduce_while(:ok, fn folder, :ok ->
      case Policy.authorize_folder(actor, "folder.manage", folder.path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp folders(ids) do
    ids = ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    with {:ok, uuids} <- cast_folder_ids(ids) do
      found = Repo.all(from f in FolderRecord, where: f.id in ^uuids, order_by: f.id)

      if length(found) == length(uuids),
        do: {:ok, Enum.sort_by(found, & &1.id)},
        else: {:error, :folder_not_found}
    end
  end

  defp cast_folder_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, :folder_not_found}}
      end
    end)
  end

  @spec record_event(String.t(), Bastion.Fleet.DeviceEvent.type(), map(), Actor.t() | nil) :: :ok
  def record_event(id, type, data, actor \\ nil) do
    journal(id, type, data, actor)
    Bastion.Events.publish({:device, id}, %DeviceChanged{id: id, change: :seen})
    :ok
  end

  @spec mark_seen(String.t(), map()) :: :ok
  def mark_seen(id, attrs) do
    changes =
      [last_seen_at: now()] ++
        Enum.filter([last_ip: attrs[:ip], firmware_version: attrs[:firmware_version]], fn {_, v} ->
          v
        end)

    Repo.update_all(from(d in DeviceRecord, where: d.id == ^id), set: changes)
    :ok
  end

  defp lock(id) do
    with {:ok, uuid} <- cast_id(id),
         %DeviceRecord{} = record <-
           Repo.one(from d in DeviceRecord, where: d.id == ^uuid, lock: "FOR UPDATE") do
      {:ok, Repo.preload(record, :folders)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp name_taken?(name) do
    lowered = String.downcase(name)
    Repo.exists?(from d in DeviceRecord, where: fragment("lower(?)", d.name) == ^lowered)
  end

  defp lock_by_device_id(device_id) do
    Repo.one(from d in DeviceRecord, where: d.device_id == ^device_id, lock: "FOR UPDATE")
    |> Repo.preload(:folders)
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp create(device),
    do: %DeviceRecord{} |> DeviceRecord.changeset(device) |> Repo.insert() |> result()

  defp persist(record, device),
    do: record |> DeviceRecord.changeset(device) |> Repo.update() |> result()

  defp result({:ok, record}),
    do: {:ok, record |> Repo.preload(:folders) |> DeviceRecord.to_domain()}

  defp result({:error, changeset}) do
    if Keyword.has_key?(changeset.errors, :name),
      do: {:error, :name_taken},
      else: {:error, :invalid}
  end

  defp journal(id, type, data, actor \\ nil)

  defp journal(id, type, data, %Actor{user_id: user_id, username: username})
       when is_binary(user_id),
       do: journal(id, type, Map.put(data, :by, username))

  defp journal(id, type, data, _actor),
    do: Repo.insert!(%DeviceEventRecord{device_id: id, type: type, data: data})

  defp changed(id, change), do: {[:fleet, {:device, id}], %DeviceChanged{id: id, change: change}}

  defp now, do: DateTime.utc_now(:second)
end
