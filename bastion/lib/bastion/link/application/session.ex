defmodule Bastion.Link.Application.Session do
  @behaviour WebSock
  require Logger

  alias Bastion.Fleet
  alias Bastion.Fleet.Events.{DeviceApproved, DeviceChanged, DeviceRevoked}
  alias Bastion.Link.Application.Presence
  alias Bastion.Link.Domain.Protocol

  @hb_interval_s 15
  @hb_timeout :timer.seconds(45)
  @hello_timeout :timer.seconds(10)
  @ping_interval :timer.seconds(30)

  @impl true
  def init(%{ip: ip} = opts) do
    state = %{
      phase: :hello,
      ip: ip,
      cert: nil,
      device: nil,
      device_id: nil,
      fw: nil,
      hb_timer: nil
    }

    Process.send_after(self(), :hello_timeout, @hello_timeout)

    case opts[:cert_der] do
      nil -> {:ok, state}
      der -> verify_client(der, state)
    end
  end

  defp verify_client(der, state) do
    with {:ok, %{common_name: cn, serial: serial}} <- Bastion.PKI.client_certificate_identity(der),
         %{status: :approved, certificate_serial: ^serial} = device <- Fleet.find_by_device_id(cn) do
      {:ok, %{state | cert: %{device_id: cn}, device: device}}
    else
      _ ->
        Logger.info("link: client certificate refused (#{state.ip})")
        close(:forbidden, "certificate not accepted", state)
    end
  end

  @impl true
  def handle_in({frame, opcode: :text}, state) do
    case Protocol.decode(frame) do
      {:ok, message} -> handle_message(message, state)
      {:error, :too_big} -> close(:too_big, "frame too big", state)
      {:error, :protocol} -> close(:protocol, "bad message", state)
    end
  end

  def handle_in({_data, opcode: :binary}, %{phase: :device} = state), do: {:ok, state}

  def handle_in({_data, opcode: :binary}, state),
    do: close(:protocol, "unexpected binary frame", state)

  defp handle_message({:hello, %{v: v}}, state) when v != 1,
    do: close(:version, "unsupported version", state)

  defp handle_message({:hello, hello}, %{phase: :hello, cert: %{device_id: cn}} = state) do
    if hello.device_id == cn,
      do: start_device(hello, state),
      else: close(:forbidden, "device_id mismatch", state)
  end

  defp handle_message({:hello, hello}, %{phase: :hello} = state) do
    state = %{state | phase: :enroll, device_id: hello.device_id, fw: hello.fw}
    Process.send_after(self(), :ping, @ping_interval)
    {:push, {:text, Protocol.welcome(:enroll, @hb_interval_s, now_ms())}, state}
  end

  defp handle_message({:enroll, enroll}, %{phase: :enroll} = state) do
    attrs = %{
      device_id: state.device_id,
      name: enroll.name,
      csr_pem: enroll.csr,
      firmware_version: state.fw,
      ip: state.ip
    }

    case Fleet.submit_request(attrs) do
      {:ok, :pending} ->
        device = Fleet.find_by_device_id(state.device_id)
        Fleet.subscribe(device.id)
        Logger.info("link: enrollment request from #{state.device_id} (#{state.ip})")

        {:push, {:text, Protocol.enroll_status(:pending)},
         %{state | phase: :waiting, device: device}}

      {:ok, {:approved, cert_pem}} ->
        {:push, {:text, Protocol.enroll_approved(cert_pem)}, %{state | phase: :done}}

      {:error, reason} when reason in [:rate_limited, :too_many_requests, :fleet_full] ->
        close(:rate_limited, "too many requests", state)

      {:error, :key_mismatch} ->
        {:push, {:text, Protocol.enroll_status(:rejected)}, %{state | phase: :done}}

      {:error, reason} ->
        Logger.info("link: enrollment from #{state.device_id} refused: #{inspect(reason)}")
        close(:protocol, "invalid request", state)
    end
  end

  defp handle_message({:hb, hb}, %{phase: :device, device: device} = state) do
    Presence.update(device.id, %{
      rtt: hb.rtt,
      rssi: hb.rssi,
      uptime: hb.uptime,
      heap: hb.heap,
      last_hb: DateTime.utc_now(:second)
    })

    {:push, {:text, Protocol.hb_ack(hb.seq, hb.ts, now_ms())}, reset_hb_timer(state)}
  end

  defp handle_message(_message, state), do: close(:protocol, "unexpected message", state)

  defp start_device(hello, %{device: device} = state) do
    Presence.register(device.id, %{
      ip: state.ip,
      fw: hello.fw,
      connected_at: DateTime.utc_now(:second)
    })

    Fleet.mark_seen(device.id, %{ip: state.ip, firmware_version: hello.fw})
    Fleet.record_event(device.id, :connected, %{ip: state.ip})
    Fleet.subscribe(device.id)
    Logger.info("link: #{device.name} (#{device.device_id}) online from #{state.ip}")

    state = reset_hb_timer(%{state | phase: :device, fw: hello.fw})
    {:push, {:text, Protocol.welcome(:device, @hb_interval_s, now_ms())}, state}
  end

  @impl true
  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(
        {:event, %DeviceApproved{id: id, certificate_pem: pem}},
        %{phase: :waiting, device: %{id: id}} = state
      ) do
    {:push, {:text, Protocol.enroll_approved(pem)}, %{state | phase: :done}}
  end

  def handle_info(
        {:event, %DeviceChanged{id: id, change: change}},
        %{phase: :waiting, device: %{id: id}} = state
      )
      when change in [:deleted, :rejected] do
    {:push, {:text, Protocol.enroll_status(:rejected)}, %{state | phase: :done}}
  end

  def handle_info({:event, %DeviceRevoked{id: id}}, %{phase: :device, device: %{id: id}} = state),
    do: close(:forbidden, "revoked", state)

  def handle_info({:event, _event}, state), do: {:ok, state}

  def handle_info(:hello_timeout, %{phase: :hello} = state),
    do: close(:no_hello, "no hello", state)

  def handle_info(:hello_timeout, state), do: {:ok, state}

  def handle_info(:hb_timeout, %{phase: :device} = state),
    do: close(:no_heartbeat, "no heartbeat", state)

  def handle_info(:ping, %{phase: phase} = state) when phase in [:enroll, :waiting] do
    Process.send_after(self(), :ping, @ping_interval)
    {:push, {:ping, ""}, state}
  end

  def handle_info(:replaced, state), do: close(:normal, "replaced by a new connection", state)
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp reset_hb_timer(state) do
    if state.hb_timer, do: Process.cancel_timer(state.hb_timer)
    %{state | hb_timer: Process.send_after(self(), :hb_timeout, @hb_timeout)}
  end

  defp close(reason, text, state),
    do: {:stop, :normal, {Protocol.close_code(reason), text}, state}

  defp now_ms, do: System.os_time(:millisecond)
end
