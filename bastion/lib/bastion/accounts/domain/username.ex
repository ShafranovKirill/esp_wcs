defmodule Bastion.Accounts.Domain.Username do
  @max 64

  @spec valid?(term()) :: boolean()
  def valid?(username) when is_binary(username) do
    String.length(username) in 1..@max and username =~ ~r/\A[\p{L}\p{N}._-]+\z/u
  end

  def valid?(_), do: false

  @spec normalize(String.t()) :: String.t()
  def normalize(username), do: String.downcase(username)
end
