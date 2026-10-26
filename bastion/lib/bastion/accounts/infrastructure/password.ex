defmodule Bastion.Accounts.Infrastructure.Password do
  @moduledoc "Хэш паролей — Argon2id"

  @spec hash(String.t()) :: String.t()
  def hash(password), do: Argon2.hash_pwd_salt(password)

  @spec verify(String.t(), String.t() | nil) :: boolean()
  def verify(password, nil) do
    # Время ответа не выдаёт, существует ли логин
    Argon2.no_user_verify(password: password)
    false
  end

  def verify(password, hash), do: Argon2.verify_pass(password, hash)
end
