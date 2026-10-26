defmodule Bastion.Accounts.Domain.Username do
  @moduledoc "Правила логина администратора"

  @max 64

  @doc "Логин: 1–64 символа, буквы, цифры, точка, дефис, подчёркивание"
  @spec valid?(term()) :: boolean()
  def valid?(username) when is_binary(username) do
    String.length(username) in 1..@max and username =~ ~r/\A[\p{L}\p{N}._-]+\z/u
  end

  def valid?(_), do: false

  @doc "Сравнение логинов без учёта регистра"
  @spec normalize(String.t()) :: String.t()
  def normalize(username), do: String.downcase(username)
end
