defmodule Bastion.PKI.Infrastructure.KeyVault do
  @magic "WCSK"
  @version 1
  @iterations 600_000
  @salt_len 16
  @iv_len 12
  @tag_len 16
  @key_len 32

  @spec default_iterations() :: pos_integer()
  def default_iterations, do: @iterations

  @spec encrypt(binary(), String.t(), pos_integer()) :: binary()
  def encrypt(plaintext, passphrase, iterations \\ @iterations)
      when is_binary(plaintext) and is_binary(passphrase) and is_integer(iterations) and
             iterations > 0 do
    salt = :crypto.strong_rand_bytes(@salt_len)
    iv = :crypto.strong_rand_bytes(@iv_len)
    header = <<@magic, @version, iterations::32, salt::binary>>
    key = derive(passphrase, salt, iterations)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, header, @tag_len, true)

    header <> iv <> tag <> ciphertext
  end

  @spec decrypt(binary(), String.t()) :: {:ok, binary()} | {:error, :bad_passphrase | :bad_format}
  def decrypt(
        <<@magic, @version, iterations::32, salt::binary-size(@salt_len),
          iv::binary-size(@iv_len), tag::binary-size(@tag_len), ciphertext::binary>>,
        passphrase
      )
      when is_binary(passphrase) and iterations > 0 do
    header = <<@magic, @version, iterations::32, salt::binary>>
    key = derive(passphrase, salt, iterations)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, header, tag, false) do
      :error -> {:error, :bad_passphrase}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_, _), do: {:error, :bad_format}

  defp derive(passphrase, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, passphrase, salt, iterations, @key_len)
  end
end
