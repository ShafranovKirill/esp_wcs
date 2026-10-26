defmodule Bastion.PKI.Domain.Code do
  @moduledoc """
  Код для сверки ключа человеком (`docs/protocol.md`, «Доверие и коды»).

  SHA-256 от `SubjectPublicKeyInfo` (DER), первые 6 байт, 12 hex-символов
  заглавными, группами по 4: `7F3A-91C2-B4E0`. Тот же алгоритм на ESP.
  """

  @bytes 6

  @type t :: String.t()

  @doc "Код по `SubjectPublicKeyInfo` в DER"
  @spec from_spki_der(binary()) :: t()
  def from_spki_der(spki_der) when is_binary(spki_der) do
    <<prefix::binary-size(@bytes), _::binary>> = :crypto.hash(:sha256, spki_der)

    prefix
    |> Base.encode16(case: :upper)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  @doc "Код имеет правильный вид (для проверки ввода)"
  @spec valid?(term()) :: boolean()
  def valid?(code) when is_binary(code), do: code =~ ~r/\A[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}\z/
  def valid?(_), do: false
end
