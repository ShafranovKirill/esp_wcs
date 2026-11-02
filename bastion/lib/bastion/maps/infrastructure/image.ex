defmodule Bastion.Maps.Infrastructure.Image do
  @moduledoc "Bounded header inspection. Only raster PNG, JPEG and WebP backgrounds are accepted."
  @max_bytes 20 * 1024 * 1024

  def inspect_file(path) do
    with {:ok, %{size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, data} <- File.read(path),
         {type, ext, width, height}
         when width > 0 and width <= 8000 and height > 0 and height <= 8000 <- dimensions(data) do
      {:ok, %{data: data, type: type, ext: ext, width: width, height: height}}
    else
      _ -> {:error, :invalid_image}
    end
  end

  defp dimensions(<<137, "PNG", 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, _::binary>>),
    do: {"image/png", "png", w, h}

  defp dimensions(<<255, 216, rest::binary>>), do: jpeg(rest)

  defp dimensions(
         <<"RIFF", _::little-32, "WEBPVP8X", _::little-32, _flags::32, w::little-24, h::little-24,
           _::binary>>
       ),
       do: {"image/webp", "webp", w + 1, h + 1}

  defp dimensions(
         <<"RIFF", _::little-32, "WEBPVP8L", _::little-32, 47, bits::little-32, _::binary>>
       ),
       do:
         {"image/webp", "webp", Bitwise.band(bits, 0x3FFF) + 1,
          Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}

  defp dimensions(
         <<"RIFF", _::little-32, "WEBPVP8 ", _::little-32, _::24, 157, 1, 42, w::little-16,
           h::little-16, _::binary>>
       ),
       do: {"image/webp", "webp", Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}

  defp dimensions(_), do: :invalid

  defp jpeg(<<255, 255, rest::binary>>), do: jpeg(<<255, rest::binary>>)

  defp jpeg(<<255, marker, size::16, rest::binary>>) when size >= 2 do
    case rest do
      <<segment::binary-size(^size - 2), tail::binary>> ->
        case {marker, segment} do
          {m, <<_precision, h::16, w::16, _::binary>>} when m in [192, 193, 194] ->
            {"image/jpeg", "jpg", w, h}

          _ ->
            jpeg(tail)
        end

      _ ->
        :invalid
    end
  end

  defp jpeg(_), do: :invalid
end
