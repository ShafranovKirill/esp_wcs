defmodule Bastion.Fleet.Device do
  @moduledoc """
  Агрегат «устройство» и правила его жизненного цикла (`docs/protocol.md`,
  «Состояния устройства на бастионе»). Чистые функции, без БД.

      (нет) ──заявка──▶ pending ──одобрить──▶ approved ──отозвать──▶ revoked ──удалить──▶ (нет)
                           │                                            │
                           └── отклонить ──▶ (нет) или revoked          └── новая заявка ──▶ pending

  Отклонение заявки удаляет устройство, если оно ни разу не было одобрено, —
  иначе (повторная заявка отозванного) возвращает его в `revoked` с журналом.
  """

  @request_interval_s 60

  @type status :: :pending | :approved | :revoked

  @type t :: %__MODULE__{
          id: String.t() | nil,
          device_id: String.t(),
          name: String.t(),
          status: status(),
          folder_id: String.t() | nil,
          device_code: String.t(),
          csr_pem: String.t() | nil,
          certificate_pem: String.t() | nil,
          certificate_serial: String.t() | nil,
          certificate_not_after: DateTime.t() | nil,
          firmware_version: String.t() | nil,
          last_ip: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          requested_at: DateTime.t(),
          approved_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :device_id,
    :name,
    :status,
    :folder_id,
    :device_code,
    :csr_pem,
    :certificate_pem,
    :certificate_serial,
    :certificate_not_after,
    :firmware_version,
    :last_ip,
    :last_seen_at,
    :requested_at,
    :approved_at,
    :revoked_at
  ]

  @type request :: %{
          device_id: String.t(),
          name: String.t(),
          device_code: String.t(),
          csr_pem: String.t(),
          firmware_version: String.t() | nil,
          ip: String.t() | nil
        }

  @type certificate :: %{certificate_pem: String.t(), serial: String.t(), not_after: DateTime.t()}

  @doc "Повторная заявка — не чаще, секунд"
  @spec request_interval_s() :: pos_integer()
  def request_interval_s, do: @request_interval_s

  @doc """
  Заявка устройства. `nil` — устройство новое.

  - уже одобрено тем же ключом → `{:already_approved, device}` (ESP была офлайн
    в момент одобрения и спрашивает снова — отдаём сертификат);
  - одобрено, но ключ другой → `{:error, :key_mismatch}` (сначала отозвать);
  - заявка или отзыв были меньше минуты назад → `{:error, :rate_limited}`.
  """
  @spec request(t() | nil, request(), DateTime.t()) ::
          {:ok, t()} | {:already_approved, t()} | {:error, :rate_limited | :key_mismatch}
  def request(nil, req, now) do
    {:ok,
     %__MODULE__{
       device_id: req.device_id,
       name: req.name,
       status: :pending,
       device_code: req.device_code,
       csr_pem: req.csr_pem,
       firmware_version: req.firmware_version,
       last_ip: req.ip,
       requested_at: now
     }}
  end

  def request(%__MODULE__{status: :approved} = device, req, _now) do
    if device.device_code == req.device_code,
      do: {:already_approved, device},
      else: {:error, :key_mismatch}
  end

  def request(%__MODULE__{status: status} = device, req, now)
      when status in [:pending, :revoked] do
    last =
      if status == :revoked,
        do: latest(device.requested_at, device.revoked_at),
        else: device.requested_at

    if DateTime.diff(now, last) < @request_interval_s do
      {:error, :rate_limited}
    else
      {:ok,
       %{
         device
         | status: :pending,
           device_code: req.device_code,
           csr_pem: req.csr_pem,
           firmware_version: req.firmware_version || device.firmware_version,
           last_ip: req.ip || device.last_ip,
           requested_at: now
       }}
    end
  end

  @spec approve(t(), certificate(), DateTime.t()) :: {:ok, t()} | {:error, :not_pending}
  def approve(%__MODULE__{status: :pending} = device, cert, now) do
    {:ok,
     %{
       device
       | status: :approved,
         csr_pem: nil,
         certificate_pem: cert.certificate_pem,
         certificate_serial: cert.serial,
         certificate_not_after: DateTime.truncate(cert.not_after, :second),
         approved_at: now,
         revoked_at: nil
     }}
  end

  def approve(_device, _cert, _now), do: {:error, :not_pending}

  @doc "Отклонить заявку: `:delete` — устройство новое; иначе вернуть в `revoked`"
  @spec reject(t(), DateTime.t()) :: :delete | {:ok, t()} | {:error, :not_pending}
  def reject(%__MODULE__{status: :pending, approved_at: nil}, _now), do: :delete

  def reject(%__MODULE__{status: :pending} = device, now),
    do: {:ok, %{device | status: :revoked, csr_pem: nil, revoked_at: device.revoked_at || now}}

  def reject(_device, _now), do: {:error, :not_pending}

  @spec revoke(t(), DateTime.t()) :: {:ok, t()} | {:error, :not_approved}
  def revoke(%__MODULE__{status: :approved} = device, now),
    do: {:ok, %{device | status: :revoked, certificate_pem: nil, revoked_at: now}}

  def revoke(_device, _now), do: {:error, :not_approved}

  @doc "Удалить можно только отозванное — чтобы не стереть рабочее устройство по ошибке"
  @spec delete(t()) :: :delete | {:error, :not_revoked}
  def delete(%__MODULE__{status: :revoked}), do: :delete
  def delete(_device), do: {:error, :not_revoked}

  defp latest(a, nil), do: a
  defp latest(nil, b), do: b
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
