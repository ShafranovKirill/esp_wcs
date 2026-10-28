defmodule Bastion.Accounts.Infrastructure.Password do
  @alphabet ~c"abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @generated_length 16

  @spec hash(String.t()) :: String.t()
  def hash(password), do: Argon2.hash_pwd_salt(password)

  @spec verify(String.t(), String.t() | nil) :: boolean()
  def verify(password, nil) do
    Argon2.no_user_verify(password: password)
    false
  end

  def verify(password, hash), do: Argon2.verify_pass(password, hash)

  @spec generate() :: String.t()
  def generate do
    size = length(@alphabet)
    limit = 256 - rem(256, size)

    chars =
      for <<byte <- :crypto.strong_rand_bytes(@generated_length * 2)>>,
          byte < limit,
          do: Enum.at(@alphabet, rem(byte, size))

    if length(chars) >= @generated_length,
      do: chars |> Enum.take(@generated_length) |> to_string(),
      else: generate()
  end
end
