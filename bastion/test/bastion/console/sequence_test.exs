defmodule Bastion.Console.SequenceTest do
  use ExUnit.Case, async: true
  alias Bastion.Console.Domain.Sequence

  test "normalizes Windows and Mac line endings and preserves interior empty lines" do
    {:ok, plan} =
      Sequence.new("enable\r\n\r\nconfigure terminal\r", %{"ending" => "crlf", "delay_ms" => "50"})

    assert plan.lines == ["enable", "", "configure terminal"]
    assert plan.total == 3
    assert Sequence.frame(plan) == "enable\r\n"
    assert Sequence.frame(Sequence.advance(plan)) == "\r\n"
  end

  test "rejects empty, oversized, binary and control-bearing configurations" do
    assert {:error, :sequence_empty} = Sequence.new("  \n", %{})
    assert {:error, :sequence_too_large} = Sequence.new(String.duplicate("a", 262_145), %{})
    assert {:error, :sequence_invalid_text} = Sequence.new(<<255>>, %{})
    assert {:error, :sequence_invalid_text} = Sequence.new("show\e[A", %{})
    assert {:error, :sequence_line_too_long} = Sequence.new(String.duplicate("a", 1025), %{})

    assert {:error, :sequence_too_many_lines} =
             Sequence.new(Enum.join(List.duplicate("show", 1001), "\n"), %{})

    assert {:error, :sequence_invalid_delay} = Sequence.new("show", %{"delay_ms" => %{}})
  end

  test "audit retains run identity and counters without command contents" do
    {:ok, plan} = Sequence.new("password supersecret", %{})
    stopped = plan |> Sequence.advance() |> Sequence.finish(:stopped)
    assert stopped.lines == []

    assert %{sent: 1, total: 1, status: "stopped", run_id: id, sha256: checksum} =
             Sequence.audit(stopped)

    assert id == plan.id
    assert byte_size(checksum) == 64
    refute inspect(Sequence.audit(stopped)) =~ "supersecret"
  end
end
