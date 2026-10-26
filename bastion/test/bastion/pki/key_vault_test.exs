defmodule Bastion.PKI.Infrastructure.KeyVaultTest do
  use ExUnit.Case, async: true

  alias Bastion.PKI.Infrastructure.KeyVault

  test "шифрует и расшифровывает" do
    sealed = KeyVault.encrypt("secret key", "pass", 1_000)
    refute sealed =~ "secret key"
    assert KeyVault.decrypt(sealed, "pass") == {:ok, "secret key"}
  end

  test "неверный пароль" do
    sealed = KeyVault.encrypt("secret key", "pass", 1_000)
    assert KeyVault.decrypt(sealed, "wrong") == {:error, :bad_passphrase}
  end

  test "подмена заголовка обнаруживается" do
    <<head::binary-size(5), _iterations::32, rest::binary>> =
      KeyVault.encrypt("secret", "pass", 1_000)

    assert KeyVault.decrypt(head <> <<1_001::32>> <> rest, "pass") == {:error, :bad_passphrase}
  end

  test "не наш формат" do
    assert KeyVault.decrypt("garbage", "pass") == {:error, :bad_format}
  end
end
