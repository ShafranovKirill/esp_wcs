defmodule Bastion.Accounts.Infrastructure.Password do
  @spec hash(String.t()) :: String.t()
  def hash(password), do: Argon2.hash_pwd_salt(password)

  @spec verify(String.t(), String.t() | nil) :: boolean()
  def verify(password, nil) do
    Argon2.no_user_verify(password: password)
    false
  end

  def verify(password, hash), do: Argon2.verify_pass(password, hash)
end
