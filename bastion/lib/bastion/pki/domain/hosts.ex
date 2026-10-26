defmodule Bastion.PKI.Domain.Hosts do
  @moduledoc """
  Имена и адреса, по которым к бастиону обращаются браузер и устройства, —
  они попадают в сертификат сервера (Subject Alternative Name).

  Список нормализуется (без повторов, в нижнем регистре, отсортирован), чтобы
  по сравнению списков решать, нужно ли перевыпускать сертификат.
  """

  @mdns_name "bastion.local"

  @type entry :: {:dns, String.t()} | {:ip, :inet.ip_address()}
  @type t :: [entry()]

  @doc "Имя бастиона в mDNS"
  @spec mdns_name() :: String.t()
  def mdns_name, do: @mdns_name

  @doc """
  Собирает список из имени машины, её адресов и дополнительных значений из
  настроек (`BASTION_HOSTS`: имена и IP через запятую).
  """
  @spec build(String.t() | nil, [:inet.ip_address()], [String.t()]) :: t()
  def build(hostname, addresses, extra) do
    names =
      [@mdns_name, "localhost", hostname, hostname && hostname <> ".local"]
      |> Enum.reject(&is_nil/1)

    loopback = [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

    (Enum.map(names, &parse/1) ++
       Enum.map(addresses ++ loopback, &{:ip, &1}) ++ Enum.map(extra, &parse/1))
    |> Enum.reject(&is_nil/1)
    |> normalize()
  end

  @doc "Без повторов и в устойчивом порядке"
  @spec normalize(t()) :: t()
  def normalize(entries) do
    entries
    |> Enum.map(fn
      {:dns, name} -> {:dns, String.downcase(name)}
      ip -> ip
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Разбирает имя или IP; пустые и недопустимые значения — `nil`"
  @spec parse(String.t()) :: entry() | nil
  def parse(value) when is_binary(value) do
    value = String.trim(value)

    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ip, ip}
      {:error, _} -> if dns_name?(value), do: {:dns, value}
    end
  end

  @doc "Разбирает список через запятую (значение `BASTION_HOSTS`)"
  @spec parse_list(String.t() | nil) :: [String.t()]
  def parse_list(nil), do: []

  def parse_list(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Адреса для подключения устройства (страница «Как подключить»): без localhost и loopback"
  @spec device_addresses(t()) :: [String.t()]
  def device_addresses(entries) do
    entries
    |> Enum.reject(&local_only?/1)
    |> Enum.sort_by(fn
      {:dns, @mdns_name} -> {0, ""}
      {:dns, name} -> {1, name}
      {:ip, ip} when tuple_size(ip) == 4 -> {2, to_string(:inet.ntoa(ip))}
      {:ip, ip} -> {3, to_string(:inet.ntoa(ip))}
    end)
    |> Enum.map(&format/1)
  end

  @doc "Запись в виде строки"
  @spec format(entry()) :: String.t()
  def format({:dns, name}), do: name
  def format({:ip, ip}), do: to_string(:inet.ntoa(ip))

  defp local_only?({:dns, "localhost"}), do: true
  defp local_only?({:ip, {127, _, _, _}}), do: true
  defp local_only?({:ip, {0, 0, 0, 0, 0, 0, 0, 1}}), do: true

  # Локальные IPv6-адреса канала (fe80::/10) без указания интерфейса бесполезны
  defp local_only?({:ip, {a, _, _, _, _, _, _, _}}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  defp local_only?(_), do: false

  # Имя хоста по RFC 1123: метки из букв, цифр и дефиса, до 253 символов
  defp dns_name?(value) do
    byte_size(value) in 1..253 and
      value
      |> String.split(".")
      |> Enum.all?(&(&1 =~ ~r/\A[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/))
  end
end
