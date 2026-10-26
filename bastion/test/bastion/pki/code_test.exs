defmodule Bastion.PKI.Domain.CodeTest do
  use ExUnit.Case, async: true

  alias Bastion.PKI.Domain.Code

  test "12 hex-символов группами по 4 от SHA-256 ключа" do
    code = Code.from_spki_der("any public key")
    assert Code.valid?(code)

    <<prefix::binary-size(6), _::binary>> = :crypto.hash(:sha256, "any public key")
    assert String.replace(code, "-", "") == Base.encode16(prefix)
  end

  test "valid? отвергает неверный вид" do
    refute Code.valid?("7f3a-91c2-b4e0")
    refute Code.valid?("7F3A91C2B4E0")
    refute Code.valid?(nil)
  end
end
