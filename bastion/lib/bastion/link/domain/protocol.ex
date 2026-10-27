defmodule Bastion.Link.Domain.Protocol do
  @version 1
  @max_frame 4096

  @type message ::
          {:hello, %{v: integer(), device_id: String.t(), fw: String.t(), caps: [String.t()]}}
          | {:enroll, %{name: String.t(), csr: String.t()}}
          | {:hb,
             %{
               seq: integer(),
               ts: integer(),
               rtt: integer() | nil,
               rssi: integer() | nil,
               uptime: integer() | nil,
               heap: integer() | nil
             }}

  @close_codes %{
    normal: 1000,
    protocol: 4000,
    version: 4001,
    too_big: 4002,
    forbidden: 4003,
    no_hello: 4004,
    no_heartbeat: 4005,
    rate_limited: 4008
  }

  @spec version() :: pos_integer()
  def version, do: @version

  @spec max_frame() :: pos_integer()
  def max_frame, do: @max_frame

  @spec close_code(atom()) :: pos_integer()
  def close_code(reason), do: Map.fetch!(@close_codes, reason)

  @spec decode(binary()) :: {:ok, message()} | {:error, :protocol | :too_big}
  def decode(frame) when byte_size(frame) > @max_frame, do: {:error, :too_big}

  def decode(frame) do
    case JSON.decode(frame) do
      {:ok, %{"t" => type} = msg} when is_binary(type) -> parse(type, msg)
      _ -> {:error, :protocol}
    end
  end

  defp parse("hello", %{"v" => v, "device_id" => id} = m) when is_integer(v) and is_binary(id) do
    with {:ok, fw} <- opt_string(m, "fw", 32),
         {:ok, caps} <- caps(m) do
      {:ok, {:hello, %{v: v, device_id: String.downcase(id), fw: fw, caps: caps}}}
    end
  end

  defp parse("enroll", %{"name" => name, "csr" => csr})
       when is_binary(name) and is_binary(csr) and byte_size(name) <= 64 and
              byte_size(csr) <= 2048 do
    {:ok, {:enroll, %{name: name, csr: csr}}}
  end

  defp parse("hb", %{"seq" => seq, "ts" => ts} = m) when is_integer(seq) and is_integer(ts) do
    with {:ok, rtt} <- opt_int(m, "rtt"),
         {:ok, rssi} <- opt_int(m, "rssi"),
         {:ok, uptime} <- opt_int(m, "uptime"),
         {:ok, heap} <- opt_int(m, "heap") do
      {:ok, {:hb, %{seq: seq, ts: ts, rtt: rtt, rssi: rssi, uptime: uptime, heap: heap}}}
    end
  end

  defp parse(_type, _msg), do: {:error, :protocol}

  defp opt_string(m, key, max) do
    case Map.get(m, key) do
      nil -> {:ok, nil}
      s when is_binary(s) and byte_size(s) <= max -> {:ok, s}
      _ -> {:error, :protocol}
    end
  end

  defp opt_int(m, key) do
    case Map.get(m, key) do
      nil -> {:ok, nil}
      i when is_integer(i) -> {:ok, i}
      _ -> {:error, :protocol}
    end
  end

  defp caps(m) do
    case Map.get(m, "caps", []) do
      caps when is_list(caps) and length(caps) <= 16 ->
        if Enum.all?(caps, &(is_binary(&1) and byte_size(&1) <= 32)),
          do: {:ok, caps},
          else: {:error, :protocol}

      _ ->
        {:error, :protocol}
    end
  end

  @spec welcome(:enroll | :device, pos_integer(), integer()) :: binary()
  def welcome(session, hb_s, now_ms),
    do: JSON.encode!(%{t: "welcome", v: @version, session: session, time: now_ms, hb: hb_s})

  @spec enroll_status(:pending | :rejected) :: binary()
  def enroll_status(status) when status in [:pending, :rejected],
    do: JSON.encode!(%{t: "enroll_status", status: status})

  @spec enroll_approved(String.t()) :: binary()
  def enroll_approved(cert_pem),
    do: JSON.encode!(%{t: "enroll_status", status: :approved, cert: cert_pem})

  @spec hb_ack(integer(), integer(), integer()) :: binary()
  def hb_ack(seq, ts, now_ms), do: JSON.encode!(%{t: "hb_ack", seq: seq, ts: ts, time: now_ms})
end
