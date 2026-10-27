defmodule Bastion.PKI.Domain.Code do
  @bytes 6

  @type t :: String.t()

  @spec from_spki_der(binary()) :: t()
  def from_spki_der(spki_der) when is_binary(spki_der) do
    <<prefix::binary-size(@bytes), _::binary>> = :crypto.hash(:sha256, spki_der)

    prefix
    |> Base.encode16(case: :upper)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  @spec valid?(term()) :: boolean()
  def valid?(code) when is_binary(code), do: code =~ ~r/\A[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}\z/
  def valid?(_), do: false
end
