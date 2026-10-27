defmodule Bastion.Console.Domain.Line do
  @bauds [1200, 2400, 4800, 9600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600]
  @parities %{"none" => :none, "even" => :even, "odd" => :odd}
  @break_ms 300

  @enforce_keys [:baud, :data_bits, :parity, :stop_bits]
  defstruct @enforce_keys

  @type parity :: :none | :even | :odd
  @type t :: %__MODULE__{
          baud: pos_integer(),
          data_bits: 5..8,
          parity: parity(),
          stop_bits: 1 | 2
        }

  @spec bauds() :: [pos_integer()]
  def bauds, do: @bauds

  @spec break_ms() :: pos_integer()
  def break_ms, do: @break_ms

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_line}
  def new(params) do
    with {:ok, baud} <- int(params, :baud),
         true <- baud in @bauds,
         {:ok, bits} <- int(params, :data_bits),
         true <- bits in 5..8,
         {:ok, parity} <- parity(params),
         {:ok, stop} <- int(params, :stop_bits),
         true <- stop in [1, 2] do
      {:ok, %__MODULE__{baud: baud, data_bits: bits, parity: parity, stop_bits: stop}}
    else
      _ -> {:error, :invalid_line}
    end
  end

  @spec to_args(t()) :: map()
  def to_args(%__MODULE__{} = line), do: Map.from_struct(line)

  @spec format(t() | map()) :: String.t()
  def format(%{baud: baud, data_bits: bits, parity: parity, stop_bits: stop}),
    do: "#{baud} #{bits}#{parity_letter(parity)}#{stop}"

  defp parity_letter(:none), do: "N"
  defp parity_letter(:even), do: "E"
  defp parity_letter(:odd), do: "O"

  defp int(params, key) do
    case fetch(params, key) do
      i when is_integer(i) ->
        {:ok, i}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {i, ""} -> {:ok, i}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parity(params) do
    case fetch(params, :parity) do
      p when p in [:none, :even, :odd] -> {:ok, p}
      p when is_binary(p) -> Map.fetch(@parities, p)
      _ -> :error
    end
  end

  defp fetch(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end
