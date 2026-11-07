defmodule Bastion.Link.Domain.ProtocolTest do
  use ExUnit.Case, async: true

  alias Bastion.Link.Domain.Protocol

  test "hello: device_id в нижнем регистре, caps по умолчанию" do
    assert {:ok, {:hello, %{v: 1, device_id: "7c2c678c8580", fw: "1.0", caps: []}}} =
             Protocol.decode(~s({"t":"hello","v":1,"device_id":"7C2C678C8580","fw":"1.0"}))
  end

  test "hb с необязательными полями" do
    assert {:ok, {:hb, %{seq: 1, ts: 5, rtt: nil, rssi: -60}}} =
             Protocol.decode(~s({"t":"hb","seq":1,"ts":5,"rssi":-60}))
  end

  test "UART в heartbeat проверяется, старые прошивки работают без него" do
    uart = %{
      "rx_bytes" => 12,
      "tx_bytes" => 8,
      "frame_errors" => 1,
      "parity_errors" => 0,
      "overflows" => 0,
      "rx_level" => 1
    }

    frame = %{"t" => "hb", "seq" => 1, "ts" => 5, "uart" => uart}
    assert {:ok, {:hb, %{uart: ^uart}}} = Protocol.decode(JSON.encode!(frame))

    for bad <- [
          Map.put(uart, "rx_bytes", -1),
          Map.put(uart, "rx_level", 2),
          Map.delete(uart, "overflows"),
          "invalid"
        ] do
      assert {:error, :protocol} = Protocol.decode(JSON.encode!(Map.put(frame, "uart", bad)))
    end
  end

  test "неверное — ошибка протокола" do
    for frame <- [
          "not json",
          ~s({"t":"unknown"}),
          ~s({"t":"hello","v":"1","device_id":"x"}),
          ~s({"t":"hb","seq":"1","ts":1}),
          ~s({"t":"hb","seq":1,"ts":1,"rssi":"strong"}),
          ~s({"t":"enroll","name":1,"csr":"x"}),
          ~s({"no_type":1})
        ] do
      assert {:error, :protocol} = Protocol.decode(frame), frame
    end
  end

  test "больше 4 КиБ — слишком большой кадр" do
    assert {:error, :too_big} = Protocol.decode(String.duplicate("x", 4097))
  end

  test "исходящие сообщения — JSON по спецификации" do
    assert %{"t" => "welcome", "v" => 1, "session" => "device", "hb" => 15, "time" => 7} =
             JSON.decode!(Protocol.welcome(:device, 15, 7))

    assert %{"t" => "hb_ack", "seq" => 3, "ts" => 9, "time" => 10} =
             JSON.decode!(Protocol.hb_ack(3, 9, 10))

    assert %{"status" => "approved", "cert" => "PEM"} =
             JSON.decode!(Protocol.enroll_approved("PEM"))
  end
end
