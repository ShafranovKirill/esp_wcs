defmodule Bastion.Discovery.Domain.Dns do
  import Bitwise

  @type_a 1
  @type_any 255
  @class_in 1
  @cache_flush 0x8000
  @unicast_response 0x8000
  @flags_response 0x8400
  @ttl 120
  @max_labels 32

  @type question :: %{name: String.t(), type: non_neg_integer(), unicast: boolean()}
  @type query :: %{id: non_neg_integer(), questions: [question()]}

  @spec parse_query(binary()) :: {:ok, query()} | :error
  def parse_query(<<id::16, flags::16, qd::16, _an::16, _ns::16, _ar::16, _::binary>> = packet)
      when (flags &&& 0x8000) == 0 and qd in 1..16 do
    questions(packet, 12, qd, [])
    |> case do
      {:ok, questions} -> {:ok, %{id: id, questions: questions}}
      :error -> :error
    end
  end

  def parse_query(_packet), do: :error

  @spec wants_a?(question(), String.t()) :: boolean()
  def wants_a?(%{name: name, type: type}, host),
    do: String.downcase(name) == String.downcase(host) and type in [@type_a, @type_any]

  @spec response(String.t(), [:inet.ip4_address()], keyword()) :: binary()
  def response(host, addresses, opts \\ []) do
    id = Keyword.get(opts, :id, 0)
    question = Keyword.get(opts, :question)
    name = encode_name(host)
    class = if question, do: @class_in, else: @class_in ||| @cache_flush

    answers =
      for {a, b, c, d} <- addresses,
          into: <<>>,
          do: <<name::binary, @type_a::16, class::16, @ttl::32, 4::16, a, b, c, d>>

    {qd, qd_bin} =
      if question, do: {1, <<name::binary, @type_a::16, @class_in::16>>}, else: {0, <<>>}

    <<id::16, @flags_response::16, qd::16, length(addresses)::16, 0::16, 0::16, qd_bin::binary,
      answers::binary>>
  end

  @spec encode_name(String.t()) :: binary()
  def encode_name(host) do
    labels =
      for label <- String.split(host, "."), into: <<>>, do: <<byte_size(label), label::binary>>

    labels <> <<0>>
  end

  defp questions(_packet, _offset, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp questions(packet, offset, n, acc) do
    with {:ok, labels, offset} <- read_name(packet, offset, [], 0, false),
         <<_::binary-size(^offset), type::16, class::16, _::binary>> <- packet do
      question = %{
        name: Enum.join(labels, "."),
        type: type,
        unicast: (class &&& @unicast_response) != 0
      }

      questions(packet, offset + 4, n - 1, [question | acc])
    else
      _ -> :error
    end
  end

  defp read_name(_packet, _offset, _labels, depth, _jumped) when depth > @max_labels, do: :error

  defp read_name(packet, offset, labels, depth, jumped) do
    case packet do
      <<_::binary-size(^offset), 0, _::binary>> ->
        {:ok, Enum.reverse(labels), if(jumped, do: jumped, else: offset + 1)}

      <<_::binary-size(^offset), 0b11::2, pointer::14, _::binary>> when pointer < offset ->
        read_name(packet, pointer, labels, depth + 1, jumped || offset + 2)

      <<_::binary-size(^offset), len, label::binary-size(len), _::binary>> when len < 64 ->
        read_name(packet, offset + 1 + len, [label | labels], depth + 1, jumped)

      _ ->
        :error
    end
  end
end
