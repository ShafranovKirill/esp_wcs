defmodule Bastion.Fleet.Domain.Name do
  @moduledoc """
  Имена устройств и папок: 1–64 символа после обрезки пробелов, без управляющих
  символов. Уникальность — без учёта регистра (проверяет БД).
  """

  @max 64

  @spec max_length() :: pos_integer()
  def max_length, do: @max

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :blank | :too_long | :invalid}
  def normalize(name) when is_binary(name) do
    name = name |> String.trim() |> String.replace(~r/\s+/u, " ")

    cond do
      name == "" -> {:error, :blank}
      String.length(name) > @max -> {:error, :too_long}
      name =~ ~r/[\p{Cc}\p{Cf}]/u -> {:error, :invalid}
      true -> {:ok, name}
    end
  end

  def normalize(_), do: {:error, :invalid}
end
