defmodule Mix.Tasks.Bastion.Device do
  @shortdoc "Тестовое устройство WCS Link: регистрация, mTLS, heartbeat, консоль-петля"
  use Mix.Task
  use Boundary, top_level?: true, deps: [Bastion.PKI]

  @requirements ["app.config"]

  @hb_default_s 15
  @credit 2048
  @credit_return_min 512
  @backoff_min_ms 1000
  @backoff_max_ms 60_000
  @retry_later_ms 60_000
  @connect_timeout_ms 10_000

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [id: :string, host: :string, port: :integer, name: :string, dir: :string]
      )

    id = opts[:id] || random_id()

    unless id =~ ~r/\A[0-9a-f]{12}\z/,
      do: Mix.raise("--id: 12 hex digits in lowercase, like a MAC address")

    dir = Path.join(opts[:dir] || "data/devices", id)
    File.mkdir_p!(dir)

    port = opts[:port] || Application.get_env(:bastion, Bastion.Link, [])[:port] || 7443

    device = %{
      id: id,
      name: opts[:name] || "fake-" <> String.slice(id, -4, 4),
      host: String.to_charlist(opts[:host] || "localhost"),
      port: port,
      dir: dir,
      key: load_or_create_key(dir),
      started: System.monotonic_time(:millisecond)
    }

    {:ok, code} = device |> csr() |> Bastion.PKI.device_code()
    info("device #{id}, code #{code}, state in #{dir}")

    device = Map.put(device, :root, load_or_pin_root(device))
    loop(device, @backoff_min_ms)
  end

  defp loop(device, backoff) do
    case session(device) do
      :approved ->
        loop(device, @backoff_min_ms)

      :restart ->
        Process.sleep(@backoff_min_ms)
        loop(device, @backoff_min_ms)

      :later ->
        info("next attempt in #{div(@retry_later_ms, 1000)} s")
        Process.sleep(@retry_later_ms)
        loop(device, @backoff_min_ms)

      {:retry, welcomed?} ->
        delay = if welcomed?, do: @backoff_min_ms, else: backoff
        info("reconnecting in #{delay} ms")
        Process.sleep(jitter(delay))
        loop(device, if(welcomed?, do: @backoff_min_ms, else: min(backoff * 2, @backoff_max_ms)))
    end
  end

  defp session(device) do
    cert = read(device, "cert.pem")
    kind = if cert, do: :device, else: :enroll

    with {:ok, sock} <- connect(device, cert),
         :ok <- upgrade(sock, device) do
      info("connected (#{kind})")
      :ssl.setopts(sock, active: :once)
      ws_send(sock, :text, hello(device))

      state = %{
        sock: sock,
        device: device,
        kind: kind,
        buf: <<>>,
        welcomed: false,
        hb_ref: make_ref(),
        hb_ms: @hb_default_s * 1000,
        seq: 0,
        rtt: -1,
        returned: 0,
        console: %{"baud" => 9600, "data_bits" => 8, "parity" => "none", "stop_bits" => 1}
      }

      result = receive_loop(state)
      :ssl.close(sock)
      result
    else
      {:error, reason} ->
        info("connection failed: #{inspect(reason)}")
        {:retry, false}
    end
  end

  defp receive_loop(state) do
    receive do
      {:ssl, _sock, data} ->
        :ssl.setopts(state.sock, active: :once)
        frames(%{state | buf: state.buf <> data})

      {:ssl_closed, _sock} ->
        info("connection closed")
        {:retry, state.welcomed}

      {:ssl_error, _sock, reason} ->
        info("tls error: #{inspect(reason)}")
        {:retry, state.welcomed}

      {:heartbeat, ref} when ref == state.hb_ref ->
        heartbeat(state)

      {:heartbeat, _stale} ->
        receive_loop(state)
    end
  end

  defp frames(state) do
    case parse_frame(state.buf) do
      :more ->
        receive_loop(state)

      {:frame, op, payload, rest} ->
        case on_frame(op, payload, %{state | buf: rest}) do
          {:continue, state} -> frames(state)
          result -> result
        end
    end
  end

  defp on_frame(:text, payload, state), do: on_message(JSON.decode!(payload), state)

  defp on_frame(:binary, <<2, input::binary>>, state) do
    ws_send(state.sock, :binary, <<1>> <> input)
    returned = state.returned + byte_size(input)

    if returned >= @credit_return_min do
      send_json(state, %{t: "credit", bytes: returned})
      {:continue, %{state | returned: 0}}
    else
      {:continue, %{state | returned: returned}}
    end
  end

  defp on_frame(:binary, _payload, state), do: {:continue, state}

  defp on_frame(:ping, payload, state) do
    ws_send(state.sock, :pong, payload)
    {:continue, state}
  end

  defp on_frame(:pong, _payload, state), do: {:continue, state}

  defp on_frame(:close, payload, state) do
    code =
      case payload do
        <<code::16, _::binary>> -> code
        _ -> 1005
      end

    info("closed by the bastion, code #{code}")

    cond do
      code == 4003 and state.kind == :device ->
        info("certificate refused, forgetting it")
        forget_certificate(state.device)
        :later

      code == 4008 ->
        :later

      true ->
        {:retry, state.welcomed}
    end
  end

  defp on_message(%{"t" => "welcome", "session" => session} = msg, state) do
    info("welcome: #{session} session, heartbeat #{msg["hb"]} s")
    state = %{state | welcomed: true}

    state =
      case state.kind do
        :enroll ->
          send_json(state, %{t: "enroll", name: state.device.name, csr: csr(state.device)})
          state

        :device ->
          state = %{state | hb_ms: (msg["hb"] || @hb_default_s) * 1000}
          Process.send_after(self(), {:heartbeat, state.hb_ref}, state.hb_ms)
          send_status(state)
          send_json(state, %{t: "credit", bytes: @credit})

          output(state, "\r\n[#{state.device.name}] loopback console: input is echoed back\r\n")
          state
      end

    {:continue, state}
  end

  defp on_message(%{"t" => "enroll_status", "status" => "pending"}, state) do
    info("request is pending: approve it on the bastion")
    {:continue, state}
  end

  defp on_message(%{"t" => "enroll_status", "status" => "approved", "cert" => cert}, state) do
    info("approved, reconnecting with the certificate")
    write(state.device, "cert.pem", cert)
    :approved
  end

  defp on_message(%{"t" => "enroll_status", "status" => "rejected"}, _state) do
    info("request rejected")
    :later
  end

  defp on_message(%{"t" => "hb_ack", "ts" => ts}, state),
    do: {:continue, %{state | rtt: uptime(state.device) - ts}}

  defp on_message(%{"t" => "cmd", "id" => id, "op" => op} = msg, state) do
    info("command #{op} #{inspect(msg["args"] || %{})}")
    command(op, msg["args"] || %{}, id, state)
  end

  defp on_message(msg, state) do
    info("unexpected message #{inspect(msg)}")
    {:continue, state}
  end

  defp command("console_config", args, id, state) do
    console = Map.merge(state.console, Map.take(args, Map.keys(state.console)))

    if valid_console?(console) do
      result(state, id, true)
      state = %{state | console: console}
      send_status(state)
      {:continue, state}
    else
      result(state, id, false, "invalid_args")
      {:continue, state}
    end
  end

  defp command("console_break", args, id, state) do
    output(state, "\r\n[BREAK #{args["ms"] || 300} ms]\r\n")
    result(state, id, true)
    {:continue, state}
  end

  defp command("wifi_config", %{"ssid" => ssid} = args, id, state)
       when is_binary(ssid) and ssid != "" do
    info("Wi-Fi \"#{ssid}\", password #{String.length(args["password"] || "")} chars; rebooting")
    result(state, id, true)
    :restart
  end

  defp command("reboot", _args, id, state) do
    result(state, id, true)
    info("rebooting")
    :restart
  end

  defp command("revoke", _args, id, state) do
    result(state, id, true)
    forget_certificate(state.device)
    :restart
  end

  defp command(op, _args, id, state) do
    result(state, id, false, if(op == "wifi_config", do: "invalid_args", else: "unknown_op"))
    {:continue, state}
  end

  defp valid_console?(c) do
    c["baud"] in [1200, 2400, 4800, 9600, 19_200, 38_400, 57_600, 115_200] and
      c["data_bits"] in [5, 6, 7, 8] and c["parity"] in ["none", "even", "odd"] and
      c["stop_bits"] in [1, 2]
  end

  defp heartbeat(state) do
    send_json(state, %{
      t: "hb",
      seq: state.seq,
      ts: uptime(state.device),
      rtt: state.rtt,
      rssi: -50 - :rand.uniform(20),
      uptime: div(uptime(state.device), 1000),
      heap: 300_000 + :rand.uniform(10_000)
    })

    Process.send_after(self(), {:heartbeat, state.hb_ref}, state.hb_ms)
    receive_loop(%{state | seq: state.seq + 1})
  end

  defp result(state, id, true), do: send_json(state, %{t: "cmd_result", id: id, ok: true})

  defp result(state, id, false, error),
    do: send_json(state, %{t: "cmd_result", id: id, ok: false, error: error})

  defp send_status(state),
    do: send_json(state, %{t: "status", console: state.console, ip: "127.0.0.1"})

  defp output(state, text), do: ws_send(state.sock, :binary, <<1>> <> text)

  defp send_json(state, map), do: ws_send(state.sock, :text, JSON.encode!(map))

  defp hello(device) do
    JSON.encode!(%{
      t: "hello",
      v: 1,
      device_id: device.id,
      fw: "fake-1.0",
      caps: ["console", "credit"]
    })
  end

  defp connect(device, cert_pem) do
    client_cert =
      if cert_pem do
        [
          cert: cert_pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der(),
          key: {:ECPrivateKey, X509.PrivateKey.to_der(device.key)}
        ]
      else
        []
      end

    :ssl.connect(
      device.host,
      device.port,
      [
        verify: :verify_peer,
        cacerts: [device.root],
        server_name_indication: :disable,
        versions: [:"tlsv1.3"],
        mode: :binary,
        active: false
      ] ++ client_cert,
      @connect_timeout_ms
    )
  end

  defp load_or_pin_root(device) do
    case read(device, "bastion.pem") do
      nil -> pin_root(device)
      pem -> pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()
    end
  end

  defp pin_root(device) do
    me = self()

    partial_chain = fn chain ->
      send(me, {:chain, chain})
      :unknown_ca
    end

    :ssl.connect(
      device.host,
      device.port,
      [
        verify: :verify_peer,
        cacerts: [],
        partial_chain: partial_chain,
        log_level: :warning,
        server_name_indication: :disable,
        versions: [:"tlsv1.3"],
        active: false
      ],
      @connect_timeout_ms
    )

    root =
      receive do
        {:chain, chain} -> Enum.find(chain, &self_signed?/1)
      after
        1000 ->
          Mix.raise("bastion #{device.host}:#{device.port} did not send its certificate chain")
      end

    root || Mix.raise("the chain from the bastion has no root certificate")
    info("bastion code #{Bastion.PKI.certificate_code(root)}")

    unless Mix.shell().yes?("Does it match the code on the bastion home page?"),
      do: Mix.raise("bastion not pinned")

    pem = root |> X509.Certificate.from_der!() |> X509.Certificate.to_pem()
    write(device, "bastion.pem", pem)
    root
  end

  defp self_signed?(der) do
    cert = X509.Certificate.from_der!(der)
    X509.Certificate.subject(cert) == X509.Certificate.issuer(cert)
  end

  defp upgrade(sock, device) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET /link HTTP/1.1\r\nHost: #{device.host}:#{device.port}\r\nUpgrade: websocket\r\n" <>
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"

    accept =
      Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

    with :ok <- :ssl.send(sock, request),
         {:ok, head} <- read_head(sock, <<>>) do
      [status | headers] = String.split(head, "\r\n")

      cond do
        not String.starts_with?(status, "HTTP/1.1 101") ->
          {:error, {:upgrade, status}}

        not Enum.any?(
          headers,
          &(String.downcase(&1) == "sec-websocket-accept: " <> String.downcase(accept))
        ) ->
          {:error, :bad_accept}

        true ->
          :ok
      end
    end
  end

  defp read_head(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, <<>>] ->
        {:ok, head}

      [_head, _rest] ->
        {:error, :early_data}

      [_] ->
        with {:ok, data} <- :ssl.recv(sock, 0, @connect_timeout_ms),
             do: read_head(sock, acc <> data)
    end
  end

  @opcodes %{0x1 => :text, 0x2 => :binary, 0x8 => :close, 0x9 => :ping, 0xA => :pong}

  defp parse_frame(
         <<1::1, _::3, op::4, 0::1, 126::7, len::16, payload::binary-size(len), rest::binary>>
       ),
       do: {:frame, Map.get(@opcodes, op, :unknown), payload, rest}

  defp parse_frame(
         <<1::1, _::3, op::4, 0::1, 127::7, len::64, payload::binary-size(len), rest::binary>>
       ),
       do: {:frame, Map.get(@opcodes, op, :unknown), payload, rest}

  defp parse_frame(<<1::1, _::3, op::4, 0::1, len::7, payload::binary-size(len), rest::binary>>)
       when len < 126,
       do: {:frame, Map.get(@opcodes, op, :unknown), payload, rest}

  defp parse_frame(_buf), do: :more

  defp ws_send(sock, type, payload) do
    op = @opcodes |> Enum.find(fn {_, t} -> t == type end) |> elem(0)
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    size =
      cond do
        len < 126 -> <<1::1, len::7>>
        len < 65_536 -> <<1::1, 126::7, len::16>>
        true -> <<1::1, 127::7, len::64>>
      end

    :ssl.send(sock, [<<1::1, 0::3, op::4>>, size, mask, mask(payload, mask)])
  end

  defp mask(payload, mask) do
    pad = :binary.copy(mask, div(byte_size(payload), 4) + 1)
    :crypto.exor(payload, binary_part(pad, 0, byte_size(payload)))
  end

  defp csr(device) do
    device.key |> X509.CSR.new("/CN=#{device.id}") |> X509.CSR.to_pem()
  end

  defp load_or_create_key(dir) do
    path = Path.join(dir, "key.pem")

    if File.exists?(path) do
      path |> File.read!() |> X509.PrivateKey.from_pem!()
    else
      key = X509.PrivateKey.new_ec(:secp256r1)
      File.write!(path, X509.PrivateKey.to_pem(key))
      File.chmod!(path, 0o600)
      key
    end
  end

  defp forget_certificate(device), do: File.rm(Path.join(device.dir, "cert.pem"))

  defp read(device, name) do
    case File.read(Path.join(device.dir, name)) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end

  defp write(device, name, data), do: File.write!(Path.join(device.dir, name), data)

  defp uptime(device), do: System.monotonic_time(:millisecond) - device.started

  defp random_id, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp jitter(ms), do: div(ms * 8, 10) + :rand.uniform(div(ms * 4, 10) + 1) - 1

  defp info(text), do: Mix.shell().info("[#{Time.utc_now() |> Time.truncate(:second)}] #{text}")
end
