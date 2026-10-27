defmodule Bastion.Events do
  use Boundary, top_level?: true, deps: []

  @pubsub Bastion.PubSub

  @type topic :: atom() | {atom(), term()}

  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, encode(topic))

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, encode(topic))

  @spec publish(topic(), struct()) :: :ok | {:error, term()}
  def publish(topic, %_{} = event),
    do: Phoenix.PubSub.broadcast(@pubsub, encode(topic), {:event, event})

  defp encode(topic) when is_atom(topic), do: Atom.to_string(topic)
  defp encode({kind, id}) when is_atom(kind), do: "#{kind}:#{id}"
end
