defmodule Bastion.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Bastion.Discovery
  alias Bastion.Discovery.Domain.Dns

  @addresses [{192, 168, 1, 10}, {10, 0, 0, 5}]

  defp query(name, type, opts \\ []) do
    id = Keyword.get(opts, :id, 0)
    class = if opts[:unicast], do: 0x8001, else: 1

    <<id::16, 0::16, 1::16, 0::16, 0::16, 0::16, Dns.encode_name(name)::binary, type::16,
      class::16>>
  end

  defp answers(<<_id::16, 0x8400::16, _qd::16, an::16, _::binary>> = packet), do: {an, packet}

  test "A-запрос bastion.local — multicast-ответ со всеми адресами" do
    assert {:multicast, reply} = Discovery.answer(query("bastion.local", 1), @addresses)
    assert {2, _} = answers(reply)
    assert reply =~ <<192, 168, 1, 10>>
    assert reply =~ <<10, 0, 0, 5>>
  end

  test "регистр имени не важен, ANY тоже отвечаем" do
    assert {:multicast, _} = Discovery.answer(query("Bastion.LOCAL", 255), @addresses)
  end

  test "чужое имя, AAAA, ответы и мусор — молчим" do
    assert Discovery.answer(query("printer.local", 1), @addresses) == :ignore
    assert Discovery.answer(query("bastion.local", 28), @addresses) == :ignore
    assert Discovery.answer(<<0::16, 0x8400::16, 0::64>>, @addresses) == :ignore
    assert Discovery.answer(<<1, 2, 3>>, @addresses) == :ignore
    assert Discovery.answer(query("bastion.local", 1), []) == :ignore
  end

  test "бит QU — unicast-ответ" do
    assert {:unicast, _} = Discovery.answer(query("bastion.local", 1, unicast: true), @addresses)
  end

  test "запрос не с порта 5353 (legacy) — unicast с тем же id и вопросом" do
    packet = query("bastion.local", 1, id: 0xBEEF)

    assert {:unicast, <<0xBEEF::16, 0x8400::16, 1::16, 2::16, _::binary>>} =
             Bastion.Discovery.Infrastructure.Responder.answer(
               packet,
               @addresses,
               "bastion.local",
               50_000
             )
  end

  test "сжатые имена разбираются, петли указателей — нет" do
    name = Dns.encode_name("bastion.local")

    packet =
      <<0::16, 0::16, 2::16, 0::16, 0::16, 0::16, name::binary, 28::16, 1::16, 0xC0, 12, 1::16,
        1::16>>

    assert {:ok, %{questions: [%{type: 28}, %{name: "bastion.local", type: 1}]}} =
             Dns.parse_query(packet)

    loop = <<0::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0xC0, 12, 1::16, 1::16>>
    assert Dns.parse_query(loop) == :error
  end
end
