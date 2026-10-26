defmodule Bastion.Fleet.Application.UnitOfWork do
  @moduledoc """
  Транзакция команды и события после неё: функция возвращает
  `{:ok, result, events}` или `{:error, reason}`; события публикуются только
  после фиксации — подписчики не увидят того, что откатилось.
  """
  alias Bastion.Repo

  @type event :: {Bastion.Events.topic() | [Bastion.Events.topic()], struct()}

  @spec run((-> {:ok, term(), [event()]} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def run(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result, events} -> {result, events}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {result, events}} ->
        Enum.each(events, &publish/1)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish({topics, event}) when is_list(topics),
    do: Enum.each(topics, &Bastion.Events.publish(&1, event))

  defp publish({topic, event}), do: Bastion.Events.publish(topic, event)
end
