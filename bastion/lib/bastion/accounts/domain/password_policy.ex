defmodule Bastion.Accounts.Domain.PasswordPolicy do
  @min_length 12
  @placeholders ~w(change-me admin password changeme)

  @spec min_length() :: pos_integer()
  def min_length, do: @min_length

  @spec check(String.t() | nil) :: :ok | {:error, :missing | :too_short | :placeholder}
  def check(nil), do: {:error, :missing}
  def check(""), do: {:error, :missing}

  def check(password) when is_binary(password) do
    cond do
      String.downcase(password) in @placeholders -> {:error, :placeholder}
      String.length(password) < @min_length -> {:error, :too_short}
      true -> :ok
    end
  end
end
