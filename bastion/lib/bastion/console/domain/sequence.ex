defmodule Bastion.Console.Domain.Sequence do
  @max_bytes 256 * 1024
  @max_lines 1000
  @max_line_bytes 1024

  defstruct [
    :id,
    :sha256,
    :delay_ms,
    :ending,
    :waiting_since,
    lines: [],
    sent: 0,
    total: 0,
    status: :ready
  ]

  def new(text, params) when is_binary(text) and is_map(params) do
    with true <- byte_size(text) <= @max_bytes || {:error, :sequence_too_large},
         true <- String.valid?(text) || {:error, :sequence_invalid_text},
         {:ok, delay} <- delay(params["delay_ms"] || "500"),
         {:ok, ending} <- ending(params["ending"] || "cr") do
      normalized = text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
      lines = normalized |> String.trim_trailing("\n") |> String.split("\n")

      cond do
        String.trim(normalized) == "" ->
          {:error, :sequence_empty}

        length(lines) > @max_lines ->
          {:error, :sequence_too_many_lines}

        Enum.any?(lines, &(byte_size(&1) > @max_line_bytes)) ->
          {:error, :sequence_line_too_long}

        Regex.match?(~r/[\x00-\x08\x0b-\x1f\x7f]/, normalized) ->
          {:error, :sequence_invalid_text}

        true ->
          {:ok,
           %__MODULE__{
             id: Ecto.UUID.generate(),
             sha256: Base.encode16(:crypto.hash(:sha256, normalized), case: :lower),
             delay_ms: delay,
             ending: ending,
             lines: lines,
             total: length(lines)
           }}
      end
    end
  end

  def new(_, _), do: {:error, :sequence_invalid_text}

  defp delay(value) when is_binary(value) or is_integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 50 and n <= 5000 -> {:ok, n}
      _ -> {:error, :sequence_invalid_delay}
    end
  end

  defp delay(_), do: {:error, :sequence_invalid_delay}

  defp ending("cr"), do: {:ok, "\r"}
  defp ending("crlf"), do: {:ok, "\r\n"}
  defp ending("lf"), do: {:ok, "\n"}
  defp ending(_), do: {:error, :sequence_invalid_text}

  def frame(%__MODULE__{lines: [line | _], ending: ending}), do: line <> ending

  def advance(%__MODULE__{} = sequence),
    do: %{sequence | lines: tl(sequence.lines), sent: sequence.sent + 1, waiting_since: nil}

  def finish(%__MODULE__{} = sequence, status), do: %{sequence | status: status, lines: []}

  def audit(%__MODULE__{} = sequence) do
    %{
      op: "command_sequence",
      run_id: sequence.id,
      status: to_string(sequence.status),
      sent: sequence.sent,
      total: sequence.total,
      sha256: sequence.sha256
    }
  end
end
